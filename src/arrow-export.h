// Minimal producer for the stable Arrow C Data Interface:
// https://arrow.apache.org/docs/format/CDataInterface.html
// No Arrow C++ dependency is required to build the SAS reader.
#ifndef ANOTHERSAS7BDAT_ARROW_EXPORT_H
#define ANOTHERSAS7BDAT_ARROW_EXPORT_H

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#ifndef ARROW_C_DATA_INTERFACE
#define ARROW_C_DATA_INTERFACE
struct ArrowSchema {
    const char *format, *name, *metadata;
    int64_t flags, n_children;
    ArrowSchema **children, *dictionary;
    void (*release)(ArrowSchema*);
    void* private_data;
};
struct ArrowArray {
    int64_t length, null_count, offset, n_buffers, n_children;
    const void** buffers;
    ArrowArray **children, *dictionary;
    void (*release)(ArrowArray*);
    void* private_data;
};
#endif

namespace sas_arrow {

template<class T> void destroy(T* value) noexcept {
    if (!value) return;
    if (value->release) value->release(value);
    delete value;
}
template<class T> using Owner = std::unique_ptr<T, decltype(&destroy<T>)>;

struct SchemaStorage {
    std::string format, name, metadata;
    std::vector<ArrowSchema*> children;
    ~SchemaStorage() { for (auto* child : children) destroy(child); }
};

struct ArrayStorage {
    std::vector<uint8_t> validity;
    std::vector<int32_t> offsets, days;
    std::vector<int64_t> instants;
    std::vector<double> numbers;
    std::vector<char> text;
    std::vector<const void*> buffers;
    std::vector<ArrowArray*> children;
    ~ArrayStorage() { for (auto* child : children) destroy(child); }
};

inline void release_schema(ArrowSchema* value) noexcept {
    auto* storage = static_cast<SchemaStorage*>(value->private_data);
    value->release = nullptr;
    value->private_data = nullptr;
    delete storage;
}
inline void release_array(ArrowArray* value) noexcept {
    auto* storage = static_cast<ArrayStorage*>(value->private_data);
    value->release = nullptr;
    value->private_data = nullptr;
    delete storage;
}

inline Owner<ArrowSchema> schema(const std::string& format, const std::string& name) {
    Owner<ArrowSchema> result(new ArrowSchema{}, destroy<ArrowSchema>);
    auto storage = std::make_unique<SchemaStorage>();
    storage->format = format;
    storage->name = name;
    result->format = storage->format.c_str();
    result->name = storage->name.c_str();
    result->flags = 2; // ARROW_FLAG_NULLABLE
    result->release = release_schema;
    result->private_data = storage.release();
    return result;
}
inline Owner<ArrowArray> array(int64_t rows) {
    Owner<ArrowArray> result(new ArrowArray{}, destroy<ArrowArray>);
    auto storage = std::make_unique<ArrayStorage>();
    result->length = rows;
    result->release = release_array;
    result->private_data = storage.release();
    return result;
}

// Metadata lengths/counts use native-endian int32 as specified by the ABI.
inline void append_int(std::string& out, int32_t value) {
    out.append(reinterpret_cast<const char*>(&value), sizeof(value));
}
inline void metadata(ArrowSchema& schema,
                     const std::vector<std::pair<std::string, std::string>>& entries) {
    auto& storage = *static_cast<SchemaStorage*>(schema.private_data);
    append_int(storage.metadata, static_cast<int32_t>(entries.size()));
    for (const auto& entry : entries) {
        append_int(storage.metadata, static_cast<int32_t>(entry.first.size()));
        storage.metadata += entry.first;
        append_int(storage.metadata, static_cast<int32_t>(entry.second.size()));
        storage.metadata += entry.second;
    }
    schema.metadata = storage.metadata.data();
}

inline void finish(ArrowSchema& schema) {
    auto& storage = *static_cast<SchemaStorage*>(schema.private_data);
    schema.n_children = storage.children.size();
    schema.children = storage.children.data();
}
inline void finish(ArrowArray& array) {
    auto& storage = *static_cast<ArrayStorage*>(array.private_data);
    array.n_buffers = storage.buffers.size();
    array.buffers = storage.buffers.data();
    array.n_children = storage.children.size();
    array.children = storage.children.data();
}

inline void validity(ArrayStorage& storage, int rows) {
    storage.validity.assign((static_cast<size_t>(rows) + 7) / 8, 0);
}
inline void valid(ArrayStorage& storage, int row) {
    storage.validity[row / 8] |= static_cast<uint8_t>(1U << (row % 8));
}

// The consumer moves the structs and owns the release callbacks. Finalizers
// release only unconsumed exports; no callback accesses R or the SAS reader.
inline void finalize_array(SEXP ptr) {
    destroy(static_cast<ArrowArray*>(R_ExternalPtrAddr(ptr)));
    R_ClearExternalPtr(ptr);
}
inline void finalize_schema(SEXP ptr) {
    destroy(static_cast<ArrowSchema*>(R_ExternalPtrAddr(ptr)));
    R_ClearExternalPtr(ptr);
}
inline Rcpp::RObject export_array(Owner<ArrowArray> value) {
    Rcpp::RObject ptr(R_MakeExternalPtr(value.get(), R_NilValue, R_NilValue));
    R_RegisterCFinalizerEx(ptr, finalize_array, TRUE);
    value.release();
    return ptr;
}
inline Rcpp::RObject export_schema(Owner<ArrowSchema> value) {
    Rcpp::RObject ptr(R_MakeExternalPtr(value.get(), R_NilValue, R_NilValue));
    R_RegisterCFinalizerEx(ptr, finalize_schema, TRUE);
    value.release();
    return ptr;
}

} // namespace sas_arrow
#endif
