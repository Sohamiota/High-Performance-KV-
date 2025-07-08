🧠 **High-Performance KV Store (C++17)**

A fast, thread-safe in-memory key-value store inspired by Redis. It supports LRU eviction, persistence through snapshots, CLI tools, and real-time performance stats.

---

**What This Project Does**

This project gives you a production-ready key-value store, ideal for systems that require:

* Ultra-fast `get/set` operations
* In-memory caching with limited size
* Thread safety for concurrent access
* Binary snapshot persistence for durability
* Custom benchmarks and a clean CLI interface

---

**Main Features**

• Blazing-fast O(1) LRU eviction
• Thread-safe read/write using shared mutexes
• Binary snapshot save/load
• Command-line interface for manual ops
• Benchmarking utility to stress test performance
• Google Test unit tests included

---

**Tech Stack**

• Language: **C++17**
• Build System: **CMake**
• Testing: **Google Test**
• OS Support: Linux/macOS (with mmap & file I/O)
• Threads: **std::shared\_mutex** and atomic counters
• Project Structure: Modular C++ with headers and CPP files

---

**Project Structure**

```
kvstore/
├── include/          # Header files (KVStore, PersistenceManager)
├── src/              # Implementations for store logic, persistence, CLI, benchmark
├── tests/            # Unit tests with Google Test
├── scripts/          # Project setup and build scripts
├── docs/             # (Optional) Documentation files
├── CMakeLists.txt    # Build configuration
├── build.sh          # Easy build script
└── README.md         # Project overview
```

---

**How to Run It Locally**

1. Clone the repo
   `git clone https://github.com/yourname/kvstore.git`
   `cd kvstore`

2. Make sure you're on a Unix-like system with CMake and g++ installed

3. Run the build script:
   `./build.sh`

4. After build:

   * Launch the CLI app:
     `./build/kvstore_cli --max-size 10000 --snapshot data.kvs`
   * Run the benchmark:
     `./build/kvstore_benchmark --ops 100000 --threads 4`
   * Run the tests:
     `make test` inside the `build/` directory

---

**Key Commands (Inside the CLI)**

* `SET key value` → Store a value
* `GET key` → Retrieve value
* `DEL key` → Delete a key
* `STATS` → Show cache hit/miss/eviction rate
* `SAVE` / `LOAD` → Manage snapshots
* `CLEAR` → Flush all data
* `EXIT` → Exit CLI

---

**Planned Enhancements**

• JSON config file support
• Cross-platform support (Windows via MSVC)
• TTL (time-to-live) expiry
• HTTP interface (via REST or gRPC)

---

**Author**

Crafted with performance and care by **\[YourNameHere]**

GitHub: [https://github.com/yourname/kvstore](https://github.com/yourname/kvstore)
(Replace with your actual GitHub link)
