#include <Rcpp.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cctype>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

extern "C" {
#include "readstat/readstat.h"
#include "readstat/readstat_io_unistd.h"
}

namespace {

std::string text_or_empty(const char* value) { return value ? value : ""; }

struct Column {
    std::string name, label, format;
    bool string;
    size_t width;
    int source_index;
};

struct Values {
    std::vector<double> numbers;
    std::vector<unsigned char> missing;
    std::vector<std::string> strings;
};

struct Batch {
    std::vector<Values> columns;
    int rows = 0;
    uint64_t bytes = 0;
    explicit Batch(size_t n) : columns(n) {}
};

// Only the main thread creates/accesses R objects. The worker owns ReadStat,
// its file descriptor, and the in-progress batch. There is no read-ahead queue:
// the worker waits at every batch boundary for the next explicit request.
class Reader {
public:
    const std::string path, encoding;
    const std::vector<std::string> selected_names;
    const uint64_t byte_target;
    std::vector<Column> columns;
    std::string file_encoding, table_name, file_label, compression;
    int64_t total_rows = 0;
    uint64_t delivered = 0;
    std::atomic<uint64_t> opens{0}, closes{0}, bytes_read{0}, seeks{0}, decoded{0};
    std::atomic<bool> cancelled{false};
    bool closed = false; // Main thread only.

    Reader(std::string p, std::vector<std::string> names, std::string enc, double bytes)
        : path(std::move(p)), encoding(std::move(enc)), selected_names(std::move(names)),
          byte_target(static_cast<uint64_t>(bytes)) { file.fd = -1; }

    ~Reader() { close(); }

    void start() { worker = std::thread(&Reader::run, this); }

    void await_schema() {
        std::unique_lock<std::mutex> lock(mutex);
        wait_main(lock, [this] { return schema_ready || done; });
        if (failure) std::rethrow_exception(failure);
        if (!schema_ready) throw std::runtime_error("SAS metadata was not available.");
    }

    Batch* next(int n) {
        std::unique_lock<std::mutex> lock(mutex);
        if (closed) throw std::runtime_error("The SAS reader is closed.");
        if (ready) return ready.get();
        if (!done) {
            requested_rows = n;
            requested = true;
            cv.notify_all();
            wait_main(lock, [this] { return ready || done; });
        }
        if (ready) return ready.get();
        if (failure) std::rethrow_exception(failure);
        return nullptr;
    }

    void consume() {
        std::lock_guard<std::mutex> lock(mutex);
        delivered += ready->rows;
        ready.reset();
    }

    void close() noexcept {
        {
            std::lock_guard<std::mutex> lock(mutex);
            cancelled.store(true);
        }
        cv.notify_all();
        if (worker.joinable()) worker.join();
        ready.reset();
        current.reset();
        closed = true;
    }

    std::string status() {
        std::lock_guard<std::mutex> lock(mutex);
        if (closed) return "closed";
        if (failure) return "error";
        return done && !ready ? "eof" : "open";
    }

private:
    std::thread worker;
    std::mutex mutex;
    std::condition_variable cv;
    bool schema_ready = false, requested = false, done = false;
    int requested_rows = 0;
    int expected_columns = 0, last_selected = -1;
    std::vector<Column> source_columns;
    std::vector<int> source_to_output;
    std::unique_ptr<Batch> current, ready;
    std::exception_ptr failure, worker_exception;
    std::string detail;
    unistd_io_ctx_t file;

    template<class Predicate>
    void wait_main(std::unique_lock<std::mutex>& lock, Predicate predicate) {
        while (!predicate()) {
            cv.wait_for(lock, std::chrono::milliseconds(50));
            lock.unlock();
            try { Rcpp::checkUserInterrupt(); }
            catch (...) { close(); throw; }
            lock.lock();
        }
    }

    // Never unwind a C++ exception through ReadStat's C callbacks.
    template<class Fn>
    int guard(Fn fn) noexcept {
        if (cancelled.load()) return READSTAT_HANDLER_ABORT;
        try { return fn(); }
        catch (...) {
            worker_exception = std::current_exception();
            return READSTAT_HANDLER_ABORT;
        }
    }

    bool await_request(std::unique_lock<std::mutex>& lock) {
        cv.wait(lock, [this] { return requested || cancelled.load(); });
        return !cancelled.load();
    }

    int finish_schema() {
        source_to_output.assign(source_columns.size(), -1);
        if (selected_names.empty()) {
            columns = source_columns;
        } else {
            for (const auto& name : selected_names) {
                bool found = false;
                for (const auto& column : source_columns) {
                    if (column.name == name) {
                        columns.push_back(column);
                        found = true;
                        break;
                    }
                }
                if (!found) throw std::runtime_error("Unknown SAS column: " + name);
            }
        }
        for (size_t i = 0; i < columns.size(); ++i) {
            source_to_output[columns[i].source_index] = static_cast<int>(i);
            last_selected = std::max(last_selected, columns[i].source_index);
        }
        std::unique_lock<std::mutex> lock(mutex);
        schema_ready = true;
        cv.notify_all();
        if (!await_request(lock)) return READSTAT_HANDLER_ABORT;
        lock.unlock();
        current.reset(new Batch(columns.size()));
        return READSTAT_HANDLER_OK;
    }

    int publish_and_wait() {
        std::unique_lock<std::mutex> lock(mutex);
        ready = std::move(current);
        requested = false;
        cv.notify_all();
        if (!await_request(lock)) return READSTAT_HANDLER_ABORT;
        lock.unlock();
        current.reset(new Batch(columns.size()));
        return READSTAT_HANDLER_OK;
    }

    static int metadata_cb(readstat_metadata_t* metadata, void* context) {
        auto* self = static_cast<Reader*>(context);
        return self->guard([&] {
            self->total_rows = metadata->row_count;
            self->expected_columns = static_cast<int>(metadata->var_count);
            self->file_encoding = metadata->file_encoding ? metadata->file_encoding : "";
            self->table_name = metadata->table_name ? metadata->table_name : "";
            self->file_label = metadata->file_label ? metadata->file_label : "";
            self->compression = metadata->compression == READSTAT_COMPRESS_BINARY ? "RDC" :
                metadata->compression == READSTAT_COMPRESS_ROWS ? "RLE" : "none";
            if (self->expected_columns == 0) {
                if (self->total_rows != 0)
                    throw std::runtime_error("SAS files with rows but no columns are unsupported.");
                return self->finish_schema();
            }
            return static_cast<int>(READSTAT_HANDLER_OK);
        });
    }

    static int variable_cb(int index, readstat_variable_t* variable, const char*, void* context) {
        auto* self = static_cast<Reader*>(context);
        return self->guard([&] {
            Column col{text_or_empty(readstat_variable_get_name(variable)),
                text_or_empty(readstat_variable_get_label(variable)),
                text_or_empty(readstat_variable_get_format(variable)),
                readstat_variable_get_type_class(variable) == READSTAT_TYPE_CLASS_STRING,
                readstat_variable_get_storage_width(variable), index};
            bool keep = self->selected_names.empty();
            for (const auto& name : self->selected_names) if (name == col.name) keep = true;
            self->source_columns.push_back(std::move(col));
            if (index + 1 == self->expected_columns) {
                int result = self->finish_schema();
                if (result != READSTAT_HANDLER_OK) return result;
            }
            return static_cast<int>(keep ? READSTAT_HANDLER_OK : READSTAT_HANDLER_SKIP_VARIABLE);
        });
    }

    static int value_cb(int, readstat_variable_t* variable, readstat_value_t value, void* context) {
        auto* self = static_cast<Reader*>(context);
        return self->guard([&] {
            const int index = readstat_variable_get_index(variable);
            const int out = self->source_to_output.at(index);
            if (out < 0) return static_cast<int>(READSTAT_HANDLER_OK);
            Values& values = self->current->columns[out];
            if (self->columns[out].string) {
                const char* text = readstat_string_value(value);
                values.strings.emplace_back(text ? text : "");
                self->current->bytes += sizeof(std::string) + values.strings.back().size() + 1 + 72;
            } else {
                values.numbers.push_back(readstat_double_value(value));
                unsigned char missing = 0;
                if (readstat_value_is_tagged_missing(value))
                    missing = static_cast<unsigned char>(readstat_value_tag(value));
                else if (readstat_value_is_system_missing(value)) missing = 1;
                values.missing.push_back(missing);
                self->current->bytes += sizeof(double) + sizeof(unsigned char);
            }
            if (index == self->last_selected) {
                ++self->current->rows;
                ++self->decoded;
                if (self->current->rows >= self->requested_rows ||
                        self->current->bytes >= self->byte_target)
                    return self->publish_and_wait();
            }
            return static_cast<int>(READSTAT_HANDLER_OK);
        });
    }

    static void error_cb(const char* message, void* context) noexcept {
        auto* self = static_cast<Reader*>(context);
        try { self->detail = message ? message : ""; }
        catch (...) { self->worker_exception = std::current_exception(); }
    }

    static int open_cb(const char* path, void* context) {
        auto* self = static_cast<Reader*>(context);
        if (self->cancelled.load()) return -1;
        int result = unistd_open_handler(path, &self->file);
        if (result != -1) ++self->opens;
        return result;
    }

    static int close_cb(void* context) {
        auto* self = static_cast<Reader*>(context);
        if (self->file.fd == -1) return 0;
        int result = unistd_close_handler(&self->file);
        self->file.fd = -1;
        ++self->closes;
        return result;
    }

    static readstat_off_t seek_cb(readstat_off_t offset, readstat_io_flags_t whence, void* context) {
        auto* self = static_cast<Reader*>(context);
        if (self->cancelled.load()) return -1;
        ++self->seeks;
        return unistd_seek_handler(offset, whence, &self->file);
    }

    static ssize_t read_cb(void* buffer, size_t length, void* context) {
        auto* self = static_cast<Reader*>(context);
        // ReadStat compares read counts with unsigned page lengths in places.
        // Report cancellation/I/O failure as a short read, never a negative
        // count that could become a huge unsigned value in that comparison.
        if (self->cancelled.load()) return 0;
        ssize_t count = unistd_read_handler(buffer, length, &self->file);
        if (count > 0) self->bytes_read.fetch_add(static_cast<uint64_t>(count));
        return count < 0 ? 0 : count;
    }

    static readstat_error_t update_cb(long, readstat_progress_handler, void*, void* context) {
        return static_cast<Reader*>(context)->cancelled.load() ? READSTAT_ERROR_USER_ABORT : READSTAT_OK;
    }

    void run() noexcept {
        std::exception_ptr error;
        try {
            std::unique_ptr<readstat_parser_t, decltype(&readstat_parser_free)>
                parser(readstat_parser_init(), readstat_parser_free);
            if (!parser) throw std::bad_alloc();
            readstat_set_io_ctx(parser.get(), this);
            readstat_set_open_handler(parser.get(), open_cb);
            readstat_set_close_handler(parser.get(), close_cb);
            readstat_set_seek_handler(parser.get(), seek_cb);
            readstat_set_read_handler(parser.get(), read_cb);
            readstat_set_update_handler(parser.get(), update_cb);
            readstat_set_metadata_handler(parser.get(), metadata_cb);
            readstat_set_variable_handler(parser.get(), variable_cb);
            readstat_set_value_handler(parser.get(), value_cb);
            readstat_set_error_handler(parser.get(), error_cb);
            if (!encoding.empty()) readstat_set_file_character_encoding(parser.get(), encoding.c_str());
            readstat_error_t result = readstat_parse_sas7bdat(parser.get(), path.c_str(), this);
            if (worker_exception) std::rethrow_exception(worker_exception);
            if (result != READSTAT_OK && !cancelled.load()) {
                std::string message = readstat_error_message(result);
                if (!detail.empty()) message += ": " + detail;
                throw std::runtime_error(message);
            }
        } catch (...) { error = std::current_exception(); }
        close_cb(this); // Also covers unexpected native exceptions.
        std::lock_guard<std::mutex> lock(mutex);
        // A failing parse never publishes a potentially incomplete current batch.
        if (!error && !cancelled.load() && current && current->rows > 0)
            ready = std::move(current);
        current.reset();
        failure = error;
        done = true;
        cv.notify_all();
    }
};

Reader& get_reader(SEXP ptr) {
    if (TYPEOF(ptr) != EXTPTRSXP || R_ExternalPtrTag(ptr) != Rf_install("AnotherSAS7bdat_reader"))
        Rcpp::stop("Invalid SAS reader pointer.");
    auto* reader = static_cast<Reader*>(R_ExternalPtrAddr(ptr));
    if (!reader) Rcpp::stop("The SAS reader pointer is no longer valid (readers cannot be serialized).");
    return *reader;
}

double missing_value(unsigned char code) {
    double value = NA_REAL;
    if (code > 1) {
        // Haven-compatible tag: low byte of the upper 32-bit NA payload.
        uint64_t bits;
        std::memcpy(&bits, &value, sizeof(bits));
        bits |= static_cast<uint64_t>(std::tolower(code)) << 32;
        std::memcpy(&value, &bits, sizeof(value));
    }
    return value;
}

Rcpp::String utf8(const std::string& x) { return Rcpp::String(x.c_str(), CE_UTF8); }

} // namespace

// [[Rcpp::export]]
SEXP native_open(std::string path, std::vector<std::string> columns, std::string encoding, double bytes) {
    std::unique_ptr<Reader> reader(new Reader(std::move(path), std::move(columns), std::move(encoding), bytes));
    reader->start();
    reader->await_schema();
    Rcpp::XPtr<Reader> ptr(reader.get(), true, Rf_install("AnotherSAS7bdat_reader"));
    reader.release();
    return ptr;
}

// [[Rcpp::export]]
SEXP native_next(SEXP ptr, int n) {
    if (n < 1) Rcpp::stop("Chunk row limit must be positive.");
    Reader& reader = get_reader(ptr);
    Batch* batch = reader.next(n);
    if (!batch) return R_NilValue;
    Rcpp::List result(reader.columns.size());
    Rcpp::CharacterVector names(reader.columns.size());
    for (size_t i = 0; i < reader.columns.size(); ++i) {
        Rcpp::checkUserInterrupt();
        const Column& col = reader.columns[i];
        const Values& values = batch->columns[i];
        names[i] = utf8(col.name);
        Rcpp::RObject output;
        if (col.string) {
            Rcpp::CharacterVector x(batch->rows);
            for (int j = 0; j < batch->rows; ++j) {
                if (j % 16384 == 0) Rcpp::checkUserInterrupt();
                x[j] = utf8(values.strings[j]);
            }
            output = x;
        } else {
            Rcpp::NumericVector x(batch->rows);
            for (int j = 0; j < batch->rows; ++j) {
                if (j % 16384 == 0) Rcpp::checkUserInterrupt();
                x[j] = values.missing[j] ? missing_value(values.missing[j]) : values.numbers[j];
            }
            output = x;
        }
        if (!col.label.empty()) output.attr("label") = utf8(col.label);
        if (!col.format.empty()) output.attr("format.sas") = utf8(col.format);
        result[i] = output;
    }
    result.attr("names") = names;
    result.attr("class") = "data.frame";
    result.attr("row.names") = Rcpp::IntegerVector::create(NA_INTEGER, -batch->rows);
    if (!reader.file_label.empty()) result.attr("label") = utf8(reader.file_label);
    reader.consume();
    return result;
}

// [[Rcpp::export]]
void native_close(SEXP ptr) { get_reader(ptr).close(); }

// [[Rcpp::export]]
Rcpp::List native_info(SEXP ptr) {
    Reader& reader = get_reader(ptr);
    Rcpp::CharacterVector names(reader.columns.size()), types(reader.columns.size()),
        formats(reader.columns.size()), labels(reader.columns.size());
    Rcpp::NumericVector widths(reader.columns.size());
    for (size_t i = 0; i < reader.columns.size(); ++i) {
        const auto& col = reader.columns[i];
        names[i] = utf8(col.name);
        types[i] = col.string ? "character" : "double";
        formats[i] = utf8(col.format);
        labels[i] = utf8(col.label);
        widths[i] = static_cast<double>(col.width);
    }
    return Rcpp::List::create(
        Rcpp::Named("path") = utf8(reader.path), Rcpp::Named("status") = reader.status(),
        Rcpp::Named("rows_total") = static_cast<double>(reader.total_rows),
        Rcpp::Named("rows_delivered") = static_cast<double>(reader.delivered),
        Rcpp::Named("rows_decoded") = static_cast<double>(reader.decoded.load()),
        Rcpp::Named("compression") = reader.compression,
        Rcpp::Named("encoding") = utf8(reader.file_encoding),
        Rcpp::Named("table_name") = utf8(reader.table_name), Rcpp::Named("label") = utf8(reader.file_label),
        Rcpp::Named("columns") = Rcpp::DataFrame::create(Rcpp::Named("name") = names,
            Rcpp::Named("type") = types, Rcpp::Named("width") = widths,
            Rcpp::Named("format") = formats, Rcpp::Named("label") = labels),
        Rcpp::Named("file_opens") = static_cast<double>(reader.opens.load()),
        Rcpp::Named("file_closes") = static_cast<double>(reader.closes.load()),
        Rcpp::Named("bytes_read") = static_cast<double>(reader.bytes_read.load()),
        Rcpp::Named("seeks") = static_cast<double>(reader.seeks.load()));
}
