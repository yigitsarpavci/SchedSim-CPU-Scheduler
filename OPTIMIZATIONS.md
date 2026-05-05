###############################################################################
# SCHEDSIM ASSEMBLY OPTIMIZATION & REFACTORING REPORT
# Target: x86-64 GNU Assembly (Linux)
###############################################################################

This report outlines professional-grade optimizations and architectural 
improvements that could be applied to the SchedSim project. These suggestions 
aim to reduce code redundancy, improve performance, and enhance memory safety.

---

1. CODE REDUNDANCY & MODULARITY: MACRO IMPLEMENTATION
------------------------------------------------------
Current Issue:
The logic for parsing multi-digit integers from the input string is repeated 
four times (burst time, arrival time, priority, and quantum). This increases 
the binary size and makes maintenance harder.

Proposed Optimization:
Implement a preprocessor macro (e.g., %macro PARSE_INT 1) to encapsulate the 
numeric accumulation logic.

2. DISPATCH LOGIC: JUMP TABLES
-------------------------------
Current Issue:
The `parse_algorithm` routine uses a chain of 'cmp' and 'je' instructions to 
dispatch to the correct simulation function. This is an O(N) operation.

Proposed Optimization:
Implement a "Jump Table" (an array of memory addresses). The dispatch would 
simply be: `jmp *(algo_table, %rax, 8)`.

3. MEMORY SAFETY: BOUNDARY CHECKING
------------------------------------
Current Issue:
The `append_output` function assumes the `output_buf` (4096 bytes) is always 
sufficient. There is no check to prevent a buffer overflow if the combined 
burst times exceed the buffer capacity.

Proposed Optimization:
Add a boundary check at the start of `append_output`:
`cmp $4096, %rcx; jge handle_overflow_error`.

4. MEMORY ARCHITECTURE: DATA TYPE PACKING
------------------------------------------
Current Issue:
The project uses 8-byte (quad-word) slots for all data, including single 
characters (proc_id) and small integers (burst/priority < 255).

Proposed Optimization:
Use appropriate data widths:
- proc_id: .byte (1 byte)
- proc_burst/priority: .byte or .word (1 or 2 bytes)

5. PERFORMANCE: FUNCTION INLINING
----------------------------------
Current Issue:
Small utility functions like `append_output` are called thousands of times 
during simulation. The overhead of 'push/pop/call/ret' can become measurable.

Proposed Optimization:
Manually inline the output logic into the inner loops of the algorithms or 
use macros for output.

6. SYSTEM INTERFACE: SYSCALL WRAPPERS
--------------------------------------
Current Issue:
Linux syscalls (read/write/exit) are manually set up every time, leading 
to boilerplate code.

Proposed Optimization:
Create macros for standard I/O:
- %macro WRITE_STDOUT buffer, len
- %macro EXIT code

7. ALGORITHMIC EFFICIENCY: RR QUEUE MANAGEMENT
-----------------------------------------------
Current Issue:
The Round Robin queue uses an array with manual circular wrapping logic.

Proposed Optimization:
If the queue size is a power of 2 (e.g., 16 instead of 10), wrapping can 
be done with a single `and $15, %reg` instead of a comparison and conditional 
jump/reset.

---
