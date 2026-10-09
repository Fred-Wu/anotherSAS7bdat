#include <Rcpp.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cctype>
#include <cstring>
#include <deque>
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
double missing_value(unsigned char code);

struct Column {
    std::string name, label, format;
    bool string;
    size_t width;
    int source_index;
};

struct Values {
    std::vector<double> numbers;
    // One arena per character column, with NUL-terminated cells and offsets.
    std::vector<char> text;
    std::vector<size_t> offsets;
};

struct Batch {
    std::vector<Values> columns;
    int rows = 0;
    uint64_t bytes = 0;
    std::vector<uint64_t> row_ends;
    explicit Batch(size_t n) : columns(n) {}

    void reset(const std::vector<Column>& schema, size_t capacity) {
        rows = 0;
        bytes = 0;
        row_ends.clear();
        row_ends.reserve(capacity);
        for (size_t i = 0; i < schema.size(); ++i) {
            auto& values = columns[i];
            if (schema[i].string) {
                values.text.clear();
                values.offsets.clear();
                values.offsets.reserve(capacity + 1);
                values.offsets.push_back(0);
                // Avoid reserving the full declared SAS width for sparse text.
                values.text.reserve(capacity * std::min<size_t>(schema[i].width + 1, 64));
            } else {
                values.numbers.clear();
                values.numbers.reserve(capacity);
            }
        }
    }
};

struct Slice {
    const Batch* batch;
    int begin, end;
};

struct Delivery {
    std::vector<Slice> slices;
    int rows = 0;
};

// Only the main thread creates/accesses R objects. The worker owns ReadStat,
// its file descriptor, and the in-progress batch. One queued batch plus one
// in-progress batch can run ahead of R. Delivered buffers return to a small
// reuse pool only after conversion finishes; returned R objects own their data.
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
          byte_target(static_cast<uint64_t>(bytes)) {
        file.fd = -1;
        recycled.reserve(2);
        // Read R's NA payload only on the main thread, before starting ReadStat.
        for (int i = 0; i < 256; ++i) missing_values[i] = missing_value(i);
    }

    ~Reader() { close(); }

    void start() { worker = std::thread(&Reader::run, this); }

    void check_interrupt() {
        try { Rcpp::checkUserInterrupt(); }
        catch (...) { close(); throw; }
    }

    void await_schema() {
        std::unique_lock<std::mutex> lock(mutex);
        wait_main(lock, [this] { return schema_ready || done; });
        if (failure) std::rethrow_exception(failure);
        if (!schema_ready) throw std::runtime_error("SAS metadata was not available.");
    }

    Delivery next(int n) {
        std::unique_lock<std::mutex> lock(mutex);
        if (closed) throw std::runtime_error("The SAS reader is closed.");
        requested_rows = n;
        requested = true;
        cv.notify_all();
        Delivery result;
        uint64_t bytes = 0;
        size_t index = 0;
        int begin = pending_offset;
        while (result.rows < n && bytes < byte_target) {
            if (index == pending.size()) {
                wait_main(lock, [this] { return ready || done; });
                if (!ready) {
                    // Completed batches remain readable before a later error.
                    if (failure && result.rows == 0) std::rethrow_exception(failure);
                    break;
                }
                pending.push_back(std::move(ready));
                cv.notify_all();
            }
            const Batch& batch = *pending[index];
            int end = begin + std::min(batch.rows - begin, n - result.rows);
            uint64_t base = begin == 0 ? 0 : batch.row_ends[begin - 1];
            // Split or combine prefetched batches when n changes. The byte
            // target still ends at the first complete row that reaches it.
            auto stop = std::lower_bound(batch.row_ends.begin() + begin,
                batch.row_ends.begin() + end, base + byte_target - bytes);
            if (stop != batch.row_ends.begin() + end)
                end = static_cast<int>(stop - batch.row_ends.begin()) + 1;
            result.slices.push_back({&batch, begin, end});
            result.rows += end - begin;
            bytes += batch.row_ends[end - 1] - base;
            ++index;
            begin = 0;
        }
        return result;
    }

    void consume(int rows) {
        std::lock_guard<std::mutex> lock(mutex);
        delivered += rows;
        while (rows > 0) {
            int count = std::min(rows, pending.front()->rows - pending_offset);
            pending_offset += count;
            rows -= count;
            if (pending_offset == pending.front()->rows) {
                if (recycled.size() < 2) recycled.push_back(std::move(pending.front()));
                pending.pop_front();
                pending_offset = 0;
            }
        }
        cv.notify_all();
    }

    void close() noexcept {
        {
            std::lock_guard<std::mutex> lock(mutex);
            cancelled.store(true);
        }
        cv.notify_all();
        if (worker.joinable()) worker.join();
        ready.reset();
        pending.clear();
        recycled.clear();
        current.reset();
        closed = true;
    }

    std::string status() {
        std::lock_guard<std::mutex> lock(mutex);
        if (closed) return "closed";
        if (failure) return "error";
        return done && !ready && pending.empty() ? "eof" : "open";
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
    std::vector<std::unique_ptr<Batch>> recycled;
    // Main-thread-owned batches awaiting successful conversion, including a
    // partially delivered head. Their total size is bounded by the requested
    // chunk plus a batch when different n values require slicing or combining.
    std::deque<std::unique_ptr<Batch>> pending;
    int pending_offset = 0;
    int batch_rows = 0;
    uint64_t minimum_row_bytes = 8; // Row-end index, in addition to cell estimates.
    double missing_values[256];
    std::exception_ptr failure, worker_exception;
    std::string detail;
    unistd_io_ctx_t file;

    template<class Predicate>
    void wait_main(std::unique_lock<std::mutex>& lock, Predicate predicate) {
        while (!predicate()) {
            cv.wait_for(lock, std::chrono::milliseconds(50));
            lock.unlock();
            check_interrupt();
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

    void prepare_batch(std::unique_lock<std::mutex>& lock) {
        batch_rows = requested_rows;
        if (!recycled.empty()) {
            current = std::move(recycled.back());
            recycled.pop_back();
        }
        lock.unlock();
        if (!current) current.reset(new Batch(columns.size()));
        uint64_t remaining = static_cast<uint64_t>(total_rows) - decoded.load();
        size_t capacity = static_cast<size_t>(std::min<uint64_t>(remaining,
            std::min<uint64_t>(batch_rows, std::max<uint64_t>(1, byte_target / minimum_row_bytes))));
        current->reset(columns, capacity);
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
            minimum_row_bytes += columns[i].string ? sizeof(std::string) + 1 + 72 : 9;
        }
        std::unique_lock<std::mutex> lock(mutex);
        schema_ready = true;
        cv.notify_all();
        if (!await_request(lock)) return READSTAT_HANDLER_ABORT;
        prepare_batch(lock);
        return READSTAT_HANDLER_OK;
    }

    int publish_and_wait() {
        std::unique_lock<std::mutex> lock(mutex);
        cv.wait(lock, [this] { return !ready || cancelled.load(); });
        if (cancelled.load()) return READSTAT_HANDLER_ABORT;
        ready = std::move(current);
        cv.notify_all();
        prepare_batch(lock);
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
                if (!text) text = "";
                size_t length = std::strlen(text);
                values.text.insert(values.text.end(), text, text + length + 1);
                values.offsets.push_back(values.text.size());
                // Keep the existing decoded-size estimate and chunk boundaries.
                self->current->bytes += sizeof(std::string) + length + 1 + 72;
            } else {
                double number;
                if (readstat_value_is_tagged_missing(value))
                    number = self->missing_values[static_cast<unsigned char>(readstat_value_tag(value))];
                else if (readstat_value_is_system_missing(value)) number = self->missing_values[1];
                else number = readstat_double_value(value);
                values.numbers.push_back(number);
                self->current->bytes += sizeof(double) + sizeof(unsigned char);
            }
            if (index == self->last_selected) {
                ++self->current->rows;
                self->current->row_ends.push_back(self->current->bytes);
                ++self->decoded;
                if (self->current->rows >= self->batch_rows ||
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
        std::unique_lock<std::mutex> lock(mutex);
        // A failing parse never publishes a potentially incomplete current batch.
        if (!error && !cancelled.load() && current && current->rows > 0) {
            cv.wait(lock, [this] { return !ready || cancelled.load(); });
            if (!cancelled.load()) ready = std::move(current);
        }
        current.reset();
        failure = error;
        done = true;
        cv.notify_all();
    }
};

Reader& get_reader(SEXP ptr) {
    if (TYPEOF(ptr) != EXTPTRSXP || R_ExternalPtrTag(ptr) != Rf_install("anotherSAS7bdat_reader"))
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
    Rcpp::XPtr<Reader> ptr(reader.get(), true, Rf_install("anotherSAS7bdat_reader"));
    reader.release();
    return ptr;
}

// [[Rcpp::export]]
SEXP native_next(SEXP ptr, int n) {
    if (n < 1) Rcpp::stop("Chunk row limit must be positive.");
    Reader& reader = get_reader(ptr);
    Delivery delivery = reader.next(n);
    if (delivery.rows == 0) return R_NilValue;
    Rcpp::List result(reader.columns.size());
    Rcpp::CharacterVector names(reader.columns.size());
    for (size_t i = 0; i < reader.columns.size(); ++i) {
        reader.check_interrupt();
        const Column& col = reader.columns[i];
        names[i] = utf8(col.name);
        Rcpp::RObject output;
        if (col.string) {
            Rcpp::CharacterVector x(Rcpp::no_init(delivery.rows));
            int dest = 0;
            for (const auto& slice : delivery.slices) {
                const Values& values = slice.batch->columns[i];
                for (int j = slice.begin; j < slice.end; ++j, ++dest) {
                    if (dest % 16384 == 0) reader.check_interrupt();
                    size_t begin = values.offsets[j];
                    size_t length = values.offsets[j + 1] - begin - 1;
                    if (length > INT_MAX) Rcpp::stop("SAS string exceeds R's string length limit.");
                    SET_STRING_ELT(x, dest, Rf_mkCharLenCE(values.text.data() + begin,
                        static_cast<int>(length), CE_UTF8));
                }
            }
            output = x;
        } else {
            Rcpp::NumericVector x(Rcpp::no_init(delivery.rows));
            int dest = 0;
            for (const auto& slice : delivery.slices) {
                const auto& numbers = slice.batch->columns[i].numbers;
                for (int j = slice.begin; j < slice.end;) {
                    reader.check_interrupt();
                    int count = std::min(16384, slice.end - j);
                    std::memcpy(REAL(x) + dest, numbers.data() + j, count * sizeof(double));
                    dest += count;
                    j += count;
                }
            }
            output = x;
        }
        if (!col.label.empty()) output.attr("label") = utf8(col.label);
        if (!col.format.empty()) output.attr("format.sas") = utf8(col.format);
        result[i] = output;
    }
    result.attr("names") = names;
    result.attr("class") = "data.frame";
    result.attr("row.names") = Rcpp::IntegerVector::create(NA_INTEGER, -delivery.rows);
    if (!reader.file_label.empty()) result.attr("label") = utf8(reader.file_label);
    reader.consume(delivery.rows);
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
