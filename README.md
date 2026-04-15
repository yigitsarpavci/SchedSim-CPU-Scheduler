# SchedSim CPU Scheduler

**SchedSim** is a high-performance, strictly zero-dependency CPU scheduling simulation engine written entirely in **x86-64 GNU Assembly**. It simulates core operating system scheduling mechanisms by evaluating and executing five major scheduling algorithms over a set of parameterized processes.

![SchedSim Thumbnail](report.pdf) <!-- Just for reference -->

## 🛠️ Overview & Architecture

Operating strictly at the hardware level, this simulation circumvents the C standard library (`libc`) entirely, employing **direct Linux System Calls** (`sys_read`, `sys_write`, `sys_exit`) for all I/O operations.

### Supported Algorithms:
1. **FCFS (First Come First Serve):** Non-preemptive, arrival-time based scheduling using stable insertion sorting.
2. **SJF (Shortest Job First):** Non-preemptive scheduling targeting minimum burst times.
3. **SRTF (Shortest Remaining Time First):** Fully preemptive scheduling, making cycle-by-cycle minimum-remaining evaluations.
4. **PF (Priority First):** Preemptive scheduling using a complex three-layer tie-breaking cascade (priority → remaining time → input order).
5. **RR (Round Robin):** Quantum-based cyclic scheduling utilizing a custom array-based circular queue implementation, handling precise padding scenarios.

### Memory & Data Structures
To combat the absence of structs and dynamic memory allocation, the system utilizes **Parallel Arrays** allocated in the `.bss` section perfectly scaled to 8-byte QWORD indices. 

- **Custom Lexer/Parser:** Implements manual string-to-integer conversion routines, handling token streams directly from the raw input buffer.
- **Circular Queues:** The Round Robin algorithm leverages a wraparound indexing technique (`modulo arithmetic` mapped physically) to manage cyclic enqueues/dequeues.

## 🚀 Capabilities

- **100% Assembly, 0% Dependencies:** Bypasses entirely high-level language runtime environments.
- **Stable Sorting:** Implements an in-place insertion sort to accurately prepare queue evaluations for non-preemptive algorithms, preserving the required input order ties.
- **Low-level Preemption Logic:** Models perfect cycle-by-cycle evaluations for `PF` and `SRTF`.

## 📁 Repository Structure

- `src/schedsim.s`: The core x86-64 Assembly codebase.
- `Makefile`: Automated build script configuring `as` (assembler) and `ld` (linker) targets.
- `report.pdf`: Detailed architectural documentation mapping memory layouts, register preservation techniques, and execution logic.

## 🛠️ Build & Run

**Requirements:** Linux environment with GNU Binutils (`as`, `ld`).

To build the project:
```bash
make
```

To execute the simulator using standard input:
```bash
./schedsim
```
*(Input formats differ based on the selected algorithm, as detailed in the attached project report).*
