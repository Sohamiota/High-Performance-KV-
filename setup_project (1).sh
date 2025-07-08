#!/bin/bash

# KV Store Project Setup Script
# This script creates the complete project structure

echo "Setting up High-Performance KV Store project..."

# Create directory structure
mkdir -p kvstore/{include,src,tests,scripts,docs}
cd kvstore

# Create main header file
cat > include/kv_store.h << 'EOF'
#pragma once

#include <unordered_map>
#include <string>
#include <memory>
#include <shared_mutex>
#include <chrono>
#include <atomic>
#include <list>
#include <optional>
#include <vector>

namespace kvstore {

class PersistenceManager;

struct CacheEntry {
    std::string value;
    std::chrono::steady_clock::time_point last_accessed;
    std::list<std::string>::iterator lru_iterator;
    
    CacheEntry(const std::string& val) 
        : value(val), last_accessed(std::chrono::steady_clock::now()) {}
};

class KVStore {
public:
    explicit KVStore(size_t max_size = 10000, const std::string& snapshot_path = "");
    ~KVStore();
    
    // Core operations
    bool set(const std::string& key, const std::string& value);
    std::optional<std::string> get(const std::string& key);
    bool del(const std::string& key);
    bool exists(const std::string& key) const;
    
    // Bulk operations
    size_t mset(const std::vector<std::pair<std::string, std::string>>& pairs);
    std::vector<std::optional<std::string>> mget(const std::vector<std::string>& keys);
    
    // Cache management
    void clear();
    size_t size() const;
    size_t capacity() const;
    
    // Persistence
    bool save_snapshot(const std::string& filename = "");
    bool load_snapshot(const std::string& filename = "");
    
    // Metrics
    struct Stats {
        std::atomic<uint64_t> hits{0};
        std::atomic<uint64_t> misses{0};
        std::atomic<uint64_t> evictions{0};
        std::atomic<uint64_t> operations{0};
        std::chrono::steady_clock::time_point start_time;
        
        Stats() : start_time(std::chrono::steady_clock::now()) {}
        
        double hit_rate() const {
            uint64_t total = hits.load() + misses.load();
            return total > 0 ? static_cast<double>(hits.load()) / total : 0.0;
        }
    };
    
    const Stats& get_stats() const { return stats_; }
    void reset_stats();

private:
    std::unordered_map<std::string, std::unique_ptr<CacheEntry>> data_;
    std::list<std::string> lru_list_;
    const size_t max_size_;
    const std::string snapshot_path_;
    mutable std::shared_mutex mutex_;
    std::unique_ptr<PersistenceManager> persistence_;
    mutable Stats stats_;
    
    void evict_lru();
    void update_lru(const std::string& key);
    void remove_from_lru(const std::string& key);
};

} // namespace kvstore
EOF

# Create persistence manager header
cat > include/persistence_manager.h << 'EOF'
#pragma once

#include <string>
#include <vector>
#include <fstream>
#include <unordered_map>
#include <memory>
#include <list>

#ifdef __unix__
#include <sys/mman.h>
#include <unistd.h>
#include <fcntl.h>
#endif

namespace kvstore {

struct CacheEntry;

class PersistenceManager {
public:
    explicit PersistenceManager(const std::string& base_path);
    ~PersistenceManager();
    
    bool save_snapshot(const std::unordered_map<std::string, std::unique_ptr<CacheEntry>>& data,
                      const std::string& filename);
    
    bool load_snapshot(std::unordered_map<std::string, std::unique_ptr<CacheEntry>>& data,
                      std::list<std::string>& lru_list,
                      const std::string& filename);

private:
    std::string base_path_;
    void write_string(std::ofstream& out, const std::string& str);
    std::string read_string(std::ifstream& in);
    static constexpr uint32_t MAGIC_NUMBER = 0x4B565354;
    static constexpr uint32_t VERSION = 1;
};

} // namespace kvstore
EOF

# Create main implementation
cat > src/kv_store.cpp << 'EOF'
#include "kv_store.h"
#include "persistence_manager.h"
#include <algorithm>
#include <iostream>

namespace kvstore {

KVStore::KVStore(size_t max_size, const std::string& snapshot_path)
    : max_size_(max_size), snapshot_path_(snapshot_path) {
    
    if (!snapshot_path_.empty()) {
        persistence_ = std::make_unique<PersistenceManager>(snapshot_path_);
        load_snapshot(snapshot_path_);
    }
}

KVStore::~KVStore() {
    if (!snapshot_path_.empty()) {
        save_snapshot(snapshot_path_);
    }
}

bool KVStore::set(const std::string& key, const std::string& value) {
    std::unique_lock<std::shared_mutex> lock(mutex_);
    stats_.operations++;
    
    auto it = data_.find(key);
    if (it != data_.end()) {
        it->second->value = value;
        it->second->last_accessed = std::chrono::steady_clock::now();
        update_lru(key);
        return true;
    }
    
    if (data_.size() >= max_size_) {
        evict_lru();
    }
    
    auto entry = std::make_unique<CacheEntry>(value);
    lru_list_.push_front(key);
    entry->lru_iterator = lru_list_.begin();
    data_[key] = std::move(entry);
    
    return true;
}

std::optional<std::string> KVStore::get(const std::string& key) {
    std::shared_lock<std::shared_mutex> shared_lock(mutex_);
    stats_.operations++;
    
    auto it = data_.find(key);
    if (it == data_.end()) {
        stats_.misses++;
        return std::nullopt;
    }
    
    stats_.hits++;
    shared_lock.unlock();
    std::unique_lock<std::shared_mutex> unique_lock(mutex_);
    
    it = data_.find(key);
    if (it == data_.end()) {
        stats_.misses++;
        return std::nullopt;
    }
    
    it->second->last_accessed = std::chrono::steady_clock::now();
    update_lru(key);
    
    return it->second->value;
}

bool KVStore::del(const std::string& key) {
    std::unique_lock<std::shared_mutex> lock(mutex_);
    stats_.operations++;
    
    auto it = data_.find(key);
    if (it == data_.end()) {
        return false;
    }
    
    remove_from_lru(key);
    data_.erase(it);
    return true;
}

bool KVStore::exists(const std::string& key) const {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    return data_.find(key) != data_.end();
}

size_t KVStore::mset(const std::vector<std::pair<std::string, std::string>>& pairs) {
    size_t count = 0;
    for (const auto& [key, value] : pairs) {
        if (set(key, value)) {
            count++;
        }
    }
    return count;
}

std::vector<std::optional<std::string>> KVStore::mget(const std::vector<std::string>& keys) {
    std::vector<std::optional<std::string>> results;
    results.reserve(keys.size());
    
    for (const auto& key : keys) {
        results.push_back(get(key));
    }
    
    return results;
}

void KVStore::evict_lru() {
    if (lru_list_.empty()) return;
    
    const std::string& lru_key = lru_list_.back();
    data_.erase(lru_key);
    lru_list_.pop_back();
    stats_.evictions++;
}

void KVStore::update_lru(const std::string& key) {
    auto it = data_.find(key);
    if (it != data_.end()) {
        lru_list_.erase(it->second->lru_iterator);
        lru_list_.push_front(key);
        it->second->lru_iterator = lru_list_.begin();
    }
}

void KVStore::remove_from_lru(const std::string& key) {
    auto it = data_.find(key);
    if (it != data_.end()) {
        lru_list_.erase(it->second->lru_iterator);
    }
}

size_t KVStore::size() const {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    return data_.size();
}

size_t KVStore::capacity() const {
    return max_size_;
}

void KVStore::clear() {
    std::unique_lock<std::shared_mutex> lock(mutex_);
    data_.clear();
    lru_list_.clear();
}

void KVStore::reset_stats() {
    stats_.hits = 0;
    stats_.misses = 0;
    stats_.evictions = 0;
    stats_.operations = 0;
    stats_.start_time = std::chrono::steady_clock::now();
}

bool KVStore::save_snapshot(const std::string& filename) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    
    if (persistence_) {
        std::string file = filename.empty() ? snapshot_path_ : filename;
        return persistence_->save_snapshot(data_, file);
    }
    
    return false;
}

bool KVStore::load_snapshot(const std::string& filename) {
    std::unique_lock<std::shared_mutex> lock(mutex_);
    
    if (persistence_) {
        std::string file = filename.empty() ? snapshot_path_ : filename;
        return persistence_->load_snapshot(data_, lru_list_, file);
    }
    
    return false;
}

} // namespace kvstore
EOF

# Create persistence manager implementation
cat > src/persistence_manager.cpp << 'EOF'
#include "persistence_manager.h"
#include "kv_store.h"
#include <iostream>
#include <algorithm>

namespace kvstore {

PersistenceManager::PersistenceManager(const std::string& base_path)
    : base_path_(base_path) {
}

PersistenceManager::~PersistenceManager() = default;

bool PersistenceManager::save_snapshot(
    const std::unordered_map<std::string, std::unique_ptr<CacheEntry>>& data,
    const std::string& filename) {
    
    try {
        std::ofstream file(filename, std::ios::binary);
        if (!file.is_open()) {
            std::cerr << "Failed to open file for writing: " << filename << std::endl;
            return false;
        }
        
        file.write(reinterpret_cast<const char*>(&MAGIC_NUMBER), sizeof(MAGIC_NUMBER));
        file.write(reinterpret_cast<const char*>(&VERSION), sizeof(VERSION));
        
        uint64_t num_entries = data.size();
        file.write(reinterpret_cast<const char*>(&num_entries), sizeof(num_entries));
        
        auto now = std::chrono::system_clock::now();
        auto timestamp = std::chrono::system_clock::to_time_t(now);
        file.write(reinterpret_cast<const char*>(&timestamp), sizeof(timestamp));
        
        std::vector<std::pair<std::string, const CacheEntry*>> sorted_entries;
        for (const auto& [key, entry] : data) {
            sorted_entries.emplace_back(key, entry.get());
        }
        
        std::sort(sorted_entries.begin(), sorted_entries.end(),
                 [](const auto& a, const auto& b) {
                     return a.second->last_accessed > b.second->last_accessed;
                 });
        
        for (const auto& [key, entry] : sorted_entries) {
            write_string(file, key);
            write_string(file, entry->value);
            
            auto time_since_epoch = entry->last_accessed.time_since_epoch();
            auto microseconds = std::chrono::duration_cast<std::chrono::microseconds>(time_since_epoch).count();
            file.write(reinterpret_cast<const char*>(&microseconds), sizeof(microseconds));
        }
        
        file.close();
        return true;
        
    } catch (const std::exception& e) {
        std::cerr << "Error saving snapshot: " << e.what() << std::endl;
        return false;
    }
}

bool PersistenceManager::load_snapshot(
    std::unordered_map<std::string, std::unique_ptr<CacheEntry>>& data,
    std::list<std::string>& lru_list,
    const std::string& filename) {
    
    try {
        std::ifstream file(filename, std::ios::binary);
        if (!file.is_open()) {
            return false;
        }
        
        uint32_t magic, version;
        file.read(reinterpret_cast<char*>(&magic), sizeof(magic));
        file.read(reinterpret_cast<char*>(&version), sizeof(version));
        
        if (magic != MAGIC_NUMBER || version != VERSION) {
            return false;
        }
        
        uint64_t num_entries;
        file.read(reinterpret_cast<char*>(&num_entries), sizeof(num_entries));
        
        std::time_t timestamp;
        file.read(reinterpret_cast<char*>(&timestamp), sizeof(timestamp));
        
        data.clear();
        lru_list.clear();
        
        for (uint64_t i = 0; i < num_entries; ++i) {
            std::string key = read_string(file);
            std::string value = read_string(file);
            
            int64_t microseconds;
            file.read(reinterpret_cast<char*>(&microseconds), sizeof(microseconds));
            
            auto entry = std::make_unique<CacheEntry>(value);
            entry->last_accessed = std::chrono::steady_clock::time_point(
                std::chrono::microseconds(microseconds));
            
            lru_list.push_back(key);
            entry->lru_iterator = std::prev(lru_list.end());
            
            data[key] = std::move(entry);
        }
        
        file.close();
        return true;
        
    } catch (const std::exception& e) {
        std::cerr << "Error loading snapshot: " << e.what() << std::endl;
        return false;
    }
}

void PersistenceManager::write_string(std::ofstream& out, const std::string& str) {
    uint32_t length = str.length();
    out.write(reinterpret_cast<const char*>(&length), sizeof(length));
    out.write(str.data(), length);
}

std::string PersistenceManager::read_string(std::ifstream& in) {
    uint32_t length;
    in.read(reinterpret_cast<char*>(&length), sizeof(length));
    
    std::string str(length, '\0');
    in.read(&str[0], length);
    
    return str;
}

} // namespace kvstore
EOF

# Create CLI application
cat > src/cli.cpp << 'EOF'
#include "kv_store.h"
#include <iostream>
#include <sstream>
#include <vector>
#include <algorithm>
#include <chrono>
#include <iomanip>

namespace kvstore {

class CLI {
public:
    explicit CLI(std::unique_ptr<KVStore> store) : store_(std::move(store)) {}
    
    void run() {
        std::cout << "KV Store CLI v1.0\n";
        std::cout << "Type 'help' for available commands\n\n";
        
        std::string line;
        while (std::cout << "kvstore> " && std::getline(std::cin, line)) {
            if (line.empty()) continue;
            
            auto tokens = tokenize(line);
            if (tokens.empty()) continue;
            
            std::string command = tokens[0];
            std::transform(command.begin(), command.end(), command.begin(), ::tolower);
            
            if (command == "quit" || command == "exit") {
                break;
            }
            
            execute_command(command, tokens);
        }
        
        std::cout << "Goodbye!\n";
    }

private:
    std::unique_ptr<KVStore> store_;
    
    std::vector<std::string> tokenize(const std::string& line) {
        std::istringstream iss(line);
        std::vector<std::string> tokens;
        std::string token;
        
        while (iss >> token) {
            tokens.push_back(token);
        }
        
        return tokens;
    }
    
    void execute_command(const std::string& command, const std::vector<std::string>& tokens) {
        auto start = std::chrono::high_resolution_clock::now();
        
        try {
            if (command == "set" && tokens.size() >= 3) {
                std::string value = tokens[2];
                for (size_t i = 3; i < tokens.size(); ++i) {
                    value += " " + tokens[i];
                }
                bool success = store_->set(tokens[1], value);
                std::cout << (success ? "OK" : "ERROR") << "\n";
            }
            else if (command == "get" && tokens.size() == 2) {
                auto value = store_->get(tokens[1]);
                if (value) {
                    std::cout << "\"" << *value << "\"\n";
                } else {
                    std::cout << "(nil)\n";
                }
            }
            else if (command == "del" && tokens.size() == 2) {
                bool success = store_->del(tokens[1]);
                std::cout << (success ? "1" : "0") << "\n";
            }
            else if (command == "exists" && tokens.size() == 2) {
                bool exists = store_->exists(tokens[1]);
                std::cout << (exists ? "1" : "0") << "\n";
            }
            else if (command == "size") {
                std::cout << store_->size() << "\n";
            }
            else if (command == "clear") {
                store_->clear();
                std::cout << "OK\n";
            }
            else if (command == "stats") {
                print_stats();
            }
            else if (command == "save") {
                std::string filename = tokens.size() >= 2 ? tokens[1] : "";
                bool success = store_->save_snapshot(filename);
                std::cout << (success ? "OK" : "ERROR") << "\n";
            }
            else if (command == "load") {
                std::string filename = tokens.size() >= 2 ? tokens[1] : "";
                bool success = store_->load_snapshot(filename);
                std::cout << (success ? "OK" : "ERROR") << "\n";
            }
            else if (command == "help") {
                print_help();
            }
            else {
                std::cout << "Unknown command. Type 'help' for usage.\n";
            }
        }
        catch (const std::exception& e) {
            std::cout << "ERROR: " << e.what() << "\n";
        }
        
        auto end = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
        
        if (command != "help" && command != "stats") {
            std::cout << "(" << duration.count() << " μs)\n";
        }
    }
    
    void print_stats() {
        const auto& stats = store_->get_stats();
        auto now = std::chrono::steady_clock::now();
        auto uptime = std::chrono::duration_cast<std::chrono::seconds>(now - stats.start_time);
        
        std::cout << "=== KV Store Statistics ===\n";
        std::cout << "Uptime: " << uptime.count() << " seconds\n";
        std::cout << "Total operations: " << stats.operations.load() << "\n";
        std::cout << "Cache hits: " << stats.hits.load() << "\n";
        std::cout << "Cache misses: " << stats.misses.load() << "\n";
        std::cout << std::fixed << std::setprecision(2);
        std::cout << "Hit rate: " << (stats.hit_rate() * 100) << "%\n";
        std::cout << "Evictions: " << stats.evictions.load() << "\n";
        std::cout << "Current size: " << store_->size() << " / " << store_->capacity() << "\n";
        std::cout << "===========================\n";
    }
    
    void print_help() {
        std::cout << "Available commands:\n";
        std::cout << "  SET key value     - Set a key-value pair\n";
        std::cout << "  GET key          - Get value for a key\n";
        std::cout << "  DEL key          - Delete a key\n";
        std::cout << "  EXISTS key       - Check if key exists\n";
        std::cout << "  SIZE             - Get number of keys\n";
        std::cout << "  CLEAR            - Remove all keys\n";
        std::cout << "  STATS            - Show performance statistics\n";
        std::cout << "  SAVE [filename]  - Save snapshot to disk\n";
        std::cout << "  LOAD [filename]  - Load snapshot from disk\n";
        std::cout << "  HELP             - Show this help\n";
        std::cout << "  QUIT/EXIT        - Exit the program\n";
    }
};

} // namespace kvstore

int main(int argc, char* argv[]) {
    size_t max_size = 10000;
    std::string snapshot_path;
    
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--max-size" && i + 1 < argc) {
            max_size = std::stoul(argv[++i]);
        } else if (arg == "--snapshot" && i + 1 < argc) {
            snapshot_path = argv[++i];
        }
    }
    
    try {
        auto store = std::make_unique<kvstore::KVStore>(max_size, snapshot_path);
        kvstore::CLI cli(std::move(store));
        cli.run();
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }
    
    return 0;
}
EOF

# Create benchmark tool
cat > src/benchmark.cpp << 'EOF'
#include "kv_store.h"
#include <chrono>
#include <random>
#include <thread>
#include <vector>
#include <iostream>
#include <iomanip>
#include <atomic>

namespace kvstore {

class Benchmark {
public:
    struct Config {
        size_t num_operations = 100000;
        size_t num_threads = 4;
        size_t key_space = 10000;
        double read_ratio = 0.8;
        size_t value_size = 100;
        bool verbose = false;
    };
    
    explicit Benchmark(KVStore& store) : store_(store) {}
    
    void run(const Config& config) {
        std::cout << "=== KV Store Benchmark ===\n";
        std::cout << "Operations: " << config.num_operations << "\n";
        std::cout << "Threads: " << config.num_threads << "\n";
        std::cout << "Key space: " << config.key_space << "\n";
        std::cout << "Read ratio: " << (config.read_ratio * 100) << "%\n";
        std::cout << "==========================\n\n";
        
        store_.reset_stats();
        
        auto start = std::chrono::high_resolution_clock::now();
        
        std::vector<std::thread> threads;
        std::atomic<size_t> completed_ops{0};
        size_t ops_per_thread = config.num_operations / config.num_threads;
        
        for (size_t i = 0; i < config.num_threads; ++i) {
            threads.emplace_back([this, &config, ops_per_thread, i, &completed_ops]() {
                worker_thread(config, ops_per_thread, i, completed_ops);
            });
        }
        
        for (auto& thread : threads) {
            thread.join();
        }
        
        auto end = std::chrono::high_resolution_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
        
        print_results(config, duration);
    }

private:
    KVStore& store_;
    
    void worker_thread(const Config& config, size_t num_ops, size_t thread_id, 
                      std::atomic<size_t>& completed_ops) {
        std::random_device rd;
        std::mt19937 gen(rd() + thread_id);
        std::uniform_int_distribution<> key_dist(0, config.key_space - 1);
        std::uniform_real_distribution<> op_dist(0.0, 1.0);
        
        std::string value(config.value_size, 'A' + (thread_id % 26));
        
        for (size_t i = 0; i < num_ops; ++i) {
            std::string key = "key_" + std::to_string(key_dist(gen));
            
            if (op_dist(gen) < config.read_ratio) {
                auto result = store_.get(key);
                if (config.verbose && result) {
                    volatile size_t len = result->length();
                    (void)len;
                }
            } else {
                store_.set(key, value);
            }
            
            completed_ops.fetch_add(1);
        }
    }
    
    void print_results(const Config& config, std::chrono::milliseconds duration) {
        const auto& stats = store_.get_stats();
        
        double ops_per_sec = static_cast<double>(config.num_operations) / 
                           (duration.count() / 1000.0);
        
        std::cout << "\n=== Benchmark Results ===\n";
        std::cout << std::fixed << std::setprecision(2);
        std::cout << "Total time: " << duration.count() << " ms\n";
        std::cout << "Operations/sec: " << std::setprecision(0) << ops_per_sec << "\n";
        std::cout << std::setprecision(3);
        std::cout << "Average latency: " << (duration.count() * 1000.0 / config.num_operations) << " μs\n";
        std::cout << std::setprecision(1);
        std::cout << "Hit rate: " << (stats.hit_rate() * 100) << "%\n";
        std::cout << "Cache size: " << store_.size() << " / " << store_.capacity() << "\n";
        std::cout << "Evictions: " << stats.evictions.load() << "\n";
        std::cout << "=========================\n";
    }
};

} // namespace kvstore

int main(int argc, char* argv[]) {
    kvstore::Benchmark::Config config;
    
    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg == "--ops" && i + 1 < argc) {
            config.num_operations = std::stoul(argv[++i]);
        } else if (arg == "--threads" && i + 1 < argc) {
            config.num_threads = std::stoul(argv[++i]);
        } else if (arg == "--keyspace" && i + 1 < argc) {
            config.key_space = std::stoul(argv[++i]);
        } else if (arg == "--read-ratio" && i + 1 < argc) {
            config.read_ratio = std::stod(argv[++i]);
        }
    }
    
    try {
        kvstore::KVStore store(50000);
        kvstore::Benchmark benchmark(store);
        benchmark.run(config);
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << std::endl;
        return 1;
    }
    
    return 0;
}
EOF

# Create test file
cat > tests/test_kv_store.cpp << 'EOF'
#include <gtest/gtest.h>
#include "kv_store.h"
#include <thread>
#include <vector>

using namespace kvstore;

class KVStoreTest : public ::testing::Test {
protected:
    void SetUp() override {
        store = std::make_unique<KVStore>(100);
    }
    
    std::unique_ptr<KVStore> store;
};

TEST_F(KVStoreTest, BasicOperations) {
    EXPECT_TRUE(store->set("key1", "value1"));
    auto result = store->get("key1");
    ASSERT_TRUE(result.has_value());
    EXPECT_EQ(*result, "value1");
    
    auto missing = store->get("nonexistent");
    EXPECT_FALSE(missing.has_value());
    
    EXPECT_TRUE(store->exists("key1"));
    EXPECT_FALSE(store->exists("nonexistent"));
    
    EXPECT_TRUE(store->del("key1"));
    EXPECT_FALSE(store->exists("key1"));
    EXPECT_FALSE(store->del("key1"));
}

TEST_F(KVStoreTest, LRUEviction) {
    KVStore small_store(3);
    
    small_store.set("key1", "value1");
    small_store.set("key2", "value2");
    small_store.set("key3", "value3");
    EXPECT_EQ(small_store.size(), 3);
    
    small_store.get("key1");
    
    small_store.set("key4", "value4");
    EXPECT_EQ(small_store.size(), 3);
    EXPECT_TRUE(small_store.exists("key1"));
    EXPECT_FALSE(small_store.exists("key2"));
    EXPECT_TRUE(small_store.exists("key3"));
    EXPECT_TRUE(small_store.exists("key4"));
}

TEST_F(KVStoreTest, Statistics) {
    auto stats = store->get_stats();
    EXPECT_EQ(stats.hits, 0);
    EXPECT_EQ(stats.misses, 0);
    
    store->set("key1", "value1");
    store->get("key1");
    store->get("key2");
    
    stats = store->get_stats();
    EXPECT_EQ(stats.hits, 1);
    EXPECT_EQ(stats.misses, 1);
    EXPECT_DOUBLE_EQ(stats.hit_rate(), 0.5);
}
EOF

# Create CMakeLists.txt
cat > CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.16)
project(kvstore VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_CXX_FLAGS_DEBUG "-g -O0 -Wall -Wextra -Wpedantic")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -DNDEBUG -march=native")

find_package(Threads REQUIRED)

include_directories(include)

set(KVSTORE_SOURCES
    src/kv_store.cpp
    src/persistence_manager.cpp
)

add_library(kvstore_lib ${KVSTORE_SOURCES})
target_link_libraries(kvstore_lib Threads::Threads)

add_executable(kvstore_cli src/cli.cpp)
target_link_libraries(kvstore_cli kvstore_lib)

add_executable(kvstore_benchmark src/benchmark.cpp)
target_link_libraries(kvstore_benchmark kvstore_lib)

option(BUILD_TESTS "Build tests" ON)
if(BUILD_TESTS)
    find_package(GTest REQUIRED)
    enable_testing()
    
    add_executable(kvstore_tests tests/test_kv_store.cpp)
    target_link_libraries(kvstore_tests kvstore_lib GTest::gtest GTest::gtest_main)
    
    add_test(NAME kvstore_unit_tests COMMAND kvstore_tests)
endif()

install(TARGETS kvstore_cli kvstore_benchmark
        RUNTIME DESTINATION bin)
EOF

# Create build script
cat > build.sh << 'EOF'
#!/bin/bash

set -e

echo "Building KV Store..."

mkdir -p build
cd build

cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=ON

make -j$(nproc)

echo "Build completed!"
echo ""
echo "Run CLI: ./kvstore_cli --max-size 10000 --snapshot data.kvs"
echo "Run benchmark: ./kvstore_benchmark --ops 100000 --threads 4"
echo "Run tests: make test"
EOF

chmod +x build.sh

# Create README
cat > README.md << 'EOF'
# High-Performance KV Store

A Redis-like in-memory key-value store implemented in C++17 with LRU eviction, persistence, and thread safety.

## Features

- **O(1) LRU Cache**: Constant-time operations using hash map + doubly linked list
- **Thread Safety**: Concurrent read/write access with shared/exclusive locks
- **Persistence**: Binary snapshot format for data durability
- **Performance Metrics**: Real-time statistics and benchmarking
- **CLI Interface**: Interactive command-line tool
- **Comprehensive Testing**: Unit tests with Google Test

## Quick Start

```bash
# Build the project
./build.sh

# Run CLI
cd build
./kvstore_cli --max-size 10000 --snapshot data.kvs

# Run benchmark
./kvstore_benchmark --ops 1000000 --threads 8 --read-ratio 0.8

# Run tests
make test