##############################################################################
# schedsim.s - CPU Scheduling Simulator
# x86-64 GNU Assembly (Linux)
#
# Supports five scheduling algorithms:
#   FCFS  - First Come First Serve (non-preemptive, arrival-based)
#   SJF   - Shortest Job First (non-preemptive, all arrive at 0)
#   SRTF  - Shortest Remaining Time First (preemptive)
#   PF    - Priority First (preemptive, lower number = higher priority)
#   RR    - Round Robin (quantum-based, all arrive at 0)
#
# Input:  single line from stdin
# Output: execution timeline string to stdout
#
# Memory layout: parallel arrays with 8-byte slots for uniform addressing.
# All I/O uses direct Linux syscalls (no C library dependency).
##############################################################################

.section .bss

# I/O buffers
input_buf:      .space 256          # raw input buffer (max input size)
output_buf:     .space 1200         # timeline output buffer

# Parallel arrays for up to 10 processes (8 bytes each, total 80 per array).
# Using 8-byte slots even for single characters enables uniform scaled
# indexed addressing: base + index * 8.
proc_id:        .space 80           # ASCII process ID (e.g., 'A' = 65)
proc_burst:     .space 80           # original burst times
proc_arrival:   .space 80           # arrival times (0 for SJF/RR)
proc_remaining: .space 80           # remaining burst (decremented during sim)
proc_priority:  .space 80           # priority values (PF only)

# Global scalars
proc_count:     .space 8            # number of processes parsed
algo_type:      .space 8            # 0=FCFS, 1=SJF, 2=SRTF, 3=PF, 4=RR
quantum_val:    .space 8            # quantum for RR
output_len:     .space 8            # current length of output_buf

# Round Robin circular queue (array-based, max 10 entries)
rr_queue:       .space 80           # process indices in queue
rr_head:        .space 8            # front pointer (dequeue index)
rr_tail:        .space 8            # back pointer (enqueue index)
rr_count:       .space 8            # current number of elements

.section .data
newline:        .byte 10

.section .text
.global _start

##############################################################################
# ENTRY POINT
##############################################################################
_start:
    # Read input from stdin
    mov     $0, %rax                # sys_read
    mov     $0, %rdi                # fd = stdin
    lea     input_buf(%rip), %rsi
    mov     $256, %rdx
    syscall

    # Null-terminate the input (rax = bytes read)
    lea     input_buf(%rip), %rsi
    movb    $0, (%rsi, %rax)

    # Initialize output length
    lea     output_len(%rip), %rdi
    movq    $0, (%rdi)

    call    parse_algorithm
    call    parse_processes

    # Dispatch to the appropriate scheduling algorithm
    lea     algo_type(%rip), %rdi
    movq    (%rdi), %rax
    cmp     $0, %rax
    je      run_fcfs
    cmp     $1, %rax
    je      run_sjf
    cmp     $2, %rax
    je      run_srtf
    cmp     $3, %rax
    je      run_pf
    cmp     $4, %rax
    je      run_rr
    jmp     do_output

##############################################################################
# PARSE ALGORITHM TYPE
#
# Identifies the algorithm from the first token and sets algo_type.
# Advances %rsi past the algorithm token and its trailing space.
# Uses first character to disambiguate; 'S' requires checking second char
# to distinguish SJF from SRTF.
##############################################################################
parse_algorithm:
    lea     input_buf(%rip), %rsi
    movzbl  (%rsi), %eax

    cmp     $'F', %al
    je      .algo_fcfs
    cmp     $'S', %al
    je      .algo_s_check
    cmp     $'P', %al
    je      .algo_pf
    cmp     $'R', %al
    je      .algo_rr
    jmp     .algo_done

.algo_fcfs:
    lea     algo_type(%rip), %rdi
    movq    $0, (%rdi)
    add     $5, %rsi                # skip "FCFS "
    jmp     .algo_done

.algo_s_check:
    # Disambiguate SJF vs SRTF by second character
    movzbl  1(%rsi), %eax
    cmp     $'J', %al
    je      .algo_sjf
    # Must be SRTF
    lea     algo_type(%rip), %rdi
    movq    $2, (%rdi)
    add     $5, %rsi                # skip "SRTF "
    jmp     .algo_done

.algo_sjf:
    lea     algo_type(%rip), %rdi
    movq    $1, (%rdi)
    add     $4, %rsi                # skip "SJF "
    jmp     .algo_done

.algo_pf:
    lea     algo_type(%rip), %rdi
    movq    $3, (%rdi)
    add     $3, %rsi                # skip "PF "
    jmp     .algo_done

.algo_rr:
    lea     algo_type(%rip), %rdi
    movq    $4, (%rdi)
    add     $3, %rsi                # skip "RR "
    jmp     .algo_done

.algo_done:
    ret

##############################################################################
# PARSE PROCESSES
#
# Parses process descriptors from the input starting at current %rsi.
# Field format varies by algorithm:
#   FCFS: ID-Burst-Arrival     SJF: ID-Burst     SRTF: ID-Burst-Arrival
#   PF:   ID-Burst-Arrival-Priority              RR:   ID-Burst ... Quantum
#
# For RR, the last token has no hyphen and is the quantum value.
# We detect this by peeking ahead for a hyphen character.
#
# Register usage:
#   rsi = input pointer       r12 = process count
#   r14 = algorithm type      rax = numeric accumulator
##############################################################################
parse_processes:
    push    %rbx
    push    %r12
    push    %r13
    push    %r14
    push    %r15
    push    %rbp

    xor     %r12, %r12              # r12 = process count = 0

    lea     algo_type(%rip), %rdi
    movq    (%rdi), %r14            # r14 = algorithm type

.parse_loop:
    # Skip leading spaces
    movzbl  (%rsi), %eax
    cmp     $' ', %al
    jne     .check_end_of_input
    inc     %rsi
    jmp     .parse_loop

.check_end_of_input:
    # End on null, newline, or carriage return
    cmp     $0, %al
    je      .parse_done
    cmp     $10, %al
    je      .parse_done
    cmp     $13, %al
    je      .parse_done

    # For RR: peek ahead to determine if this token is a process (has '-')
    # or the quantum value (digits only, no '-')
    cmp     $4, %r14
    jne     .parse_process_descriptor

    push    %rsi
    xor     %rcx, %rcx
.rr_peek_loop:
    movzbl  (%rsi, %rcx), %eax
    cmp     $0, %al
    je      .rr_peek_done
    cmp     $10, %al
    je      .rr_peek_done
    cmp     $13, %al
    je      .rr_peek_done
    cmp     $' ', %al
    je      .rr_peek_done
    cmp     $'-', %al
    je      .rr_has_hyphen
    inc     %rcx
    jmp     .rr_peek_loop

.rr_has_hyphen:
    pop     %rsi
    jmp     .parse_process_descriptor

.rr_peek_done:
    pop     %rsi
    # No hyphen found: parse as quantum (digit accumulation: rax = rax*10 + digit)
    xor     %rax, %rax
.parse_quantum_loop:
    movzbl  (%rsi), %ecx
    cmp     $'0', %cl
    jb      .store_quantum
    cmp     $'9', %cl
    ja      .store_quantum
    sub     $'0', %cl
    imul    $10, %rax, %rax
    movzx   %cl, %rcx
    add     %rcx, %rax
    inc     %rsi
    jmp     .parse_quantum_loop

.store_quantum:
    lea     quantum_val(%rip), %rdi
    movq    %rax, (%rdi)
    jmp     .parse_done

.parse_process_descriptor:
    # Field 1: process ID (single uppercase letter)
    movzbl  (%rsi), %eax
    lea     proc_id(%rip), %rdi
    movq    %rax, (%rdi, %r12, 8)
    inc     %rsi                     # skip ID
    inc     %rsi                     # skip '-'

    # Field 2: burst time (multi-digit number)
    xor     %rax, %rax
.parse_burst:
    movzbl  (%rsi), %ecx
    cmp     $'0', %cl
    jb      .burst_done
    cmp     $'9', %cl
    ja      .burst_done
    sub     $'0', %cl
    imul    $10, %rax, %rax
    movzx   %cl, %rcx
    add     %rcx, %rax
    inc     %rsi
    jmp     .parse_burst

.burst_done:
    lea     proc_burst(%rip), %rdi
    movq    %rax, (%rdi, %r12, 8)
    # Copy burst to remaining (will be decremented during simulation)
    lea     proc_remaining(%rip), %rdi
    movq    %rax, (%rdi, %r12, 8)

    # SJF and RR only have ID-Burst; skip arrival/priority parsing
    cmp     $1, %r14
    je      .set_defaults_and_next
    cmp     $4, %r14
    je      .set_defaults_and_next

    # Field 3: arrival time (FCFS, SRTF, PF)
    inc     %rsi                     # skip '-'
    xor     %rax, %rax
.parse_arrival:
    movzbl  (%rsi), %ecx
    cmp     $'0', %cl
    jb      .arrival_done
    cmp     $'9', %cl
    ja      .arrival_done
    sub     $'0', %cl
    imul    $10, %rax, %rax
    movzx   %cl, %rcx
    add     %rcx, %rax
    inc     %rsi
    jmp     .parse_arrival

.arrival_done:
    lea     proc_arrival(%rip), %rdi
    movq    %rax, (%rdi, %r12, 8)

    # Field 4: priority (PF only)
    cmp     $3, %r14
    jne     .next_process

    inc     %rsi                     # skip '-'
    xor     %rax, %rax
.parse_priority:
    movzbl  (%rsi), %ecx
    cmp     $'0', %cl
    jb      .priority_done
    cmp     $'9', %cl
    ja      .priority_done
    sub     $'0', %cl
    imul    $10, %rax, %rax
    movzx   %cl, %rcx
    add     %rcx, %rax
    inc     %rsi
    jmp     .parse_priority

.priority_done:
    lea     proc_priority(%rip), %rdi
    movq    %rax, (%rdi, %r12, 8)
    jmp     .next_process

.set_defaults_and_next:
    # SJF/RR: all arrive at 0, no priority
    lea     proc_arrival(%rip), %rdi
    movq    $0, (%rdi, %r12, 8)
    lea     proc_priority(%rip), %rdi
    movq    $0, (%rdi, %r12, 8)

.next_process:
    inc     %r12
    jmp     .parse_loop

.parse_done:
    lea     proc_count(%rip), %rdi
    movq    %r12, (%rdi)

    pop     %rbp
    pop     %r15
    pop     %r14
    pop     %r13
    pop     %r12
    pop     %rbx
    ret

##############################################################################
# APPEND CHARACTER TO OUTPUT BUFFER
#
# Appends a single character to output_buf and increments output_len.
# Input:  %al = character to append
# Preserves all caller registers via push/pop.
##############################################################################
append_output:
    push    %rdi
    push    %rcx
    lea     output_len(%rip), %rdi
    movq    (%rdi), %rcx
    lea     output_buf(%rip), %rdi
    movb    %al, (%rdi, %rcx)
    lea     output_len(%rip), %rdi
    incq    (%rdi)
    pop     %rcx
    pop     %rdi
    ret

##############################################################################
# WRITE OUTPUT AND EXIT
#
# Writes output_buf to stdout, appends a newline, and exits with code 0.
##############################################################################
do_output:
    mov     $1, %rax                # sys_write
    mov     $1, %rdi                # fd = stdout
    lea     output_buf(%rip), %rsi
    lea     output_len(%rip), %rdx
    movq    (%rdx), %rdx
    syscall

    # Write trailing newline
    mov     $1, %rax
    mov     $1, %rdi
    lea     newline(%rip), %rsi
    mov     $1, %rdx
    syscall

    mov     $60, %rax               # sys_exit
    xor     %rdi, %rdi              # exit code 0
    syscall

##############################################################################
# FCFS - First Come First Serve
#
# Non-preemptive. Processes run in order of arrival time.
# Tie-breaking: input order (stable sort preserves original ordering).
#
# Strategy: stable insertion sort on arrival time, then sequential execution.
# Idle cycles ('X') are emitted when gaps exist between process arrivals.
#
# Register usage:
#   r15 = process count     r12 = sorted index / outer loop counter
#   r13 = process index     r14 = insertion sort j counter
#   rbp = current time      rbx = temp for comparisons
#   Stack: order[10] array (80 bytes)
##############################################################################
run_fcfs:
    push    %rbx
    push    %r12
    push    %r13
    push    %r14
    push    %r15
    push    %rbp

    lea     proc_count(%rip), %rdi
    movq    (%rdi), %r15

    # Allocate order[] on stack: holds sorted process indices
    sub     $80, %rsp

    # Initialize order[i] = i
    xor     %rcx, %rcx
.fcfs_init_order:
    cmp     %r15, %rcx
    jge     .fcfs_sort_done_init
    movq    %rcx, (%rsp, %rcx, 8)
    inc     %rcx
    jmp     .fcfs_init_order

.fcfs_sort_done_init:
    # Stable insertion sort by arrival time.
    # Stopping on <= ensures stability: equal arrivals keep input order.
    mov     $1, %r12                # i = 1
.fcfs_isort_outer:
    cmp     %r15, %r12
    jge     .fcfs_sorted

    movq    (%rsp, %r12, 8), %r13   # key = order[i]
    mov     %r12, %r14
    dec     %r14                    # j = i - 1

.fcfs_isort_inner:
    cmp     $0, %r14
    jl      .fcfs_isort_insert

    movq    (%rsp, %r14, 8), %rax   # rax = order[j]
    lea     proc_arrival(%rip), %rdi
    movq    (%rdi, %rax, 8), %rbx   # arrival[order[j]]
    movq    (%rdi, %r13, 8), %rcx   # arrival[key]

    # Stop if arrival[order[j]] <= arrival[key] (stable: equal = stop)
    cmp     %rcx, %rbx
    jle     .fcfs_isort_insert

    # Shift order[j] right to order[j+1]
    lea     1(%r14), %rax
    movq    (%rsp, %r14, 8), %rbx
    movq    %rbx, (%rsp, %rax, 8)
    dec     %r14
    jmp     .fcfs_isort_inner

.fcfs_isort_insert:
    lea     1(%r14), %rax
    movq    %r13, (%rsp, %rax, 8)   # order[j+1] = key
    inc     %r12
    jmp     .fcfs_isort_outer

.fcfs_sorted:
    # Execute processes in sorted order
    xor     %r12, %r12              # sorted index = 0
    xor     %rbp, %rbp              # current_time = 0

.fcfs_run_loop:
    cmp     %r15, %r12
    jge     .fcfs_done

    movq    (%rsp, %r12, 8), %r13   # r13 = next process index

    lea     proc_arrival(%rip), %rdi
    movq    (%rdi, %r13, 8), %rax   # rax = arrival time

    # Emit idle cycles if CPU must wait for this process to arrive
.fcfs_idle_loop:
    cmp     %rax, %rbp
    jge     .fcfs_run_process
    push    %rax
    mov     $'X', %al
    call    append_output
    pop     %rax
    inc     %rbp
    jmp     .fcfs_idle_loop

.fcfs_run_process:
    lea     proc_burst(%rip), %rdi
    movq    (%rdi, %r13, 8), %rcx   # rcx = burst time
    lea     proc_id(%rip), %rdi
    movq    (%rdi, %r13, 8), %rbx   # rbx = process ID character

    # Output process ID for each burst cycle (non-preemptive: runs to completion)
.fcfs_burst_loop:
    cmp     $0, %rcx
    jle     .fcfs_next_process
    push    %rcx
    push    %rax
    mov     %bl, %al
    call    append_output
    pop     %rax
    pop     %rcx
    inc     %rbp
    dec     %rcx
    jmp     .fcfs_burst_loop

.fcfs_next_process:
    inc     %r12
    jmp     .fcfs_run_loop

.fcfs_done:
    add     $80, %rsp               # free order[] from stack
    pop     %rbp
    pop     %r15
    pop     %r14
    pop     %r13
    pop     %r12
    pop     %rbx
    jmp     do_output

##############################################################################
# SJF - Shortest Job First
#
# Non-preemptive. All processes arrive at time 0.
# Sorted by burst time (stable), then run sequentially.
# No idle cycles possible since all arrive simultaneously.
#
# Register usage: same as FCFS, but sorts on burst instead of arrival.
##############################################################################
run_sjf:
    push    %rbx
    push    %r12
    push    %r13
    push    %r14
    push    %r15
    push    %rbp

    lea     proc_count(%rip), %rdi
    movq    (%rdi), %r15

    sub     $80, %rsp               # order[10] on stack

    xor     %rcx, %rcx
.sjf_init_order:
    cmp     %r15, %rcx
    jge     .sjf_sort
    movq    %rcx, (%rsp, %rcx, 8)
    inc     %rcx
    jmp     .sjf_init_order

.sjf_sort:
    # Stable insertion sort by burst time
    mov     $1, %r12
.sjf_isort_outer:
    cmp     %r15, %r12
    jge     .sjf_sorted

    movq    (%rsp, %r12, 8), %r13   # key = order[i]
    mov     %r12, %r14
    dec     %r14

.sjf_isort_inner:
    cmp     $0, %r14
    jl      .sjf_isort_insert

    movq    (%rsp, %r14, 8), %rax
    lea     proc_burst(%rip), %rdi
    movq    (%rdi, %rax, 8), %rbx   # burst[order[j]]
    movq    (%rdi, %r13, 8), %rcx   # burst[key]

    # Stop if burst[order[j]] <= burst[key] (stable)
    cmp     %rcx, %rbx
    jle     .sjf_isort_insert

    lea     1(%r14), %rax
    movq    (%rsp, %r14, 8), %rbx
    movq    %rbx, (%rsp, %rax, 8)
    dec     %r14
    jmp     .sjf_isort_inner

.sjf_isort_insert:
    lea     1(%r14), %rax
    movq    %r13, (%rsp, %rax, 8)
    inc     %r12
    jmp     .sjf_isort_outer

.sjf_sorted:
    xor     %r12, %r12

.sjf_run_loop:
    cmp     %r15, %r12
    jge     .sjf_done

    movq    (%rsp, %r12, 8), %r13

    lea     proc_burst(%rip), %rdi
    movq    (%rdi, %r13, 8), %rcx
    lea     proc_id(%rip), %rdi
    movq    (%rdi, %r13, 8), %rbx

.sjf_burst_loop:
    cmp     $0, %rcx
    jle     .sjf_next
    push    %rcx
    mov     %bl, %al
    call    append_output
    pop     %rcx
    dec     %rcx
    jmp     .sjf_burst_loop

.sjf_next:
    inc     %r12
    jmp     .sjf_run_loop

.sjf_done:
    add     $80, %rsp
    pop     %rbp
    pop     %r15
    pop     %r14
    pop     %r13
    pop     %r12
    pop     %rbx
    jmp     do_output

##############################################################################
# SRTF - Shortest Remaining Time First
#
# Preemptive. At each clock cycle, selects the arrived process with the
# smallest remaining burst time. Runs it for exactly one cycle, then
# re-evaluates. Idle cycles emitted when no process has arrived yet.
#
# Tie-breaking: input order (lower index wins). Achieved by using strict
# less-than comparison — first process found with minimum remaining is kept.
#
# Register usage:
#   r15 = process count      rbp = current_time
#   r8  = best remaining     r9  = best index (-1 = none)
#   r14 = total burst        r13 = simulation upper bound
##############################################################################
run_srtf:
    push    %rbx
    push    %r12
    push    %r13
    push    %r14
    push    %r15
    push    %rbp

    lea     proc_count(%rip), %rdi
    movq    (%rdi), %r15

    xor     %rbp, %rbp              # current_time = 0

    # Sum all burst times to compute simulation upper bound
    xor     %r14, %r14
    xor     %rcx, %rcx
.srtf_total:
    cmp     %r15, %rcx
    jge     .srtf_calc_end
    lea     proc_burst(%rip), %rdi
    addq    (%rdi, %rcx, 8), %r14
    inc     %rcx
    jmp     .srtf_total

.srtf_calc_end:
    # Find max arrival to set upper bound: max_arrival + total_burst
    xor     %r13, %r13
    xor     %rcx, %rcx
.srtf_max_arrival:
    cmp     %r15, %rcx
    jge     .srtf_max_arrival_done
    lea     proc_arrival(%rip), %rdi
    movq    (%rdi, %rcx, 8), %rax
    cmp     %rax, %r13
    jge     .srtf_max_arrival_next
    mov     %rax, %r13
.srtf_max_arrival_next:
    inc     %rcx
    jmp     .srtf_max_arrival

.srtf_max_arrival_done:
    add     %r14, %r13              # r13 = upper bound

.srtf_cycle:
    # Check termination: sum all remaining times
    xor     %rcx, %rcx
    xor     %rax, %rax
.srtf_check_done:
    cmp     %r15, %rcx
    jge     .srtf_check_done_end
    lea     proc_remaining(%rip), %rdi
    addq    (%rdi, %rcx, 8), %rax
    inc     %rcx
    jmp     .srtf_check_done

.srtf_check_done_end:
    cmp     $0, %rax
    je      .srtf_done

    # Select: find arrived process with smallest remaining time
    movq    $999999, %r8            # best remaining (sentinel)
    movq    $-1, %r9                # best index (none)
    xor     %rcx, %rcx

.srtf_select:
    cmp     %r15, %rcx
    jge     .srtf_select_done

    # Skip completed processes (remaining == 0)
    lea     proc_remaining(%rip), %rdi
    movq    (%rdi, %rcx, 8), %rax
    cmp     $0, %rax
    jle     .srtf_select_next

    # Skip processes that haven't arrived yet
    lea     proc_arrival(%rip), %rdi
    movq    (%rdi, %rcx, 8), %rbx
    cmp     %rbp, %rbx
    jg      .srtf_select_next

    # Strict less-than: keeps first-found on ties (lower index = input order)
    cmp     %r8, %rax
    jge     .srtf_select_next

    mov     %rax, %r8               # new best remaining
    mov     %rcx, %r9               # new best index

.srtf_select_next:
    inc     %rcx
    jmp     .srtf_select

.srtf_select_done:
    # No arrived process: emit idle cycle
    cmp     $-1, %r9
    jne     .srtf_run_cycle

    mov     $'X', %al
    call    append_output
    inc     %rbp
    jmp     .srtf_cycle

.srtf_run_cycle:
    # Run selected process for one cycle
    lea     proc_id(%rip), %rdi
    movq    (%rdi, %r9, 8), %rax
    push    %rax
    call    append_output
    pop     %rax

    lea     proc_remaining(%rip), %rdi
    decq    (%rdi, %r9, 8)

    inc     %rbp
    jmp     .srtf_cycle

.srtf_done:
    pop     %rbp
    pop     %r15
    pop     %r14
    pop     %r13
    pop     %r12
    pop     %rbx
    jmp     do_output

##############################################################################
# PF - Priority First (Preemptive)
#
# At each cycle, selects the arrived process with the lowest priority number
# (lower = higher priority). Preemptive: re-evaluates every cycle.
#
# Tie-breaking cascade:
#   1. Lowest priority number wins
#   2. Shortest remaining time wins
#   3. First in input order wins (lower index)
#
# Register usage:
#   r15 = process count      rbp = current_time
#   r8  = best priority      r9  = best index (-1 = none)
#   r10 = best remaining     r11 = candidate priority
##############################################################################
run_pf:
    push    %rbx
    push    %r12
    push    %r13
    push    %r14
    push    %r15
    push    %rbp

    lea     proc_count(%rip), %rdi
    movq    (%rdi), %r15

    xor     %rbp, %rbp              # current_time = 0

.pf_cycle:
    # Check termination: sum all remaining times
    xor     %rcx, %rcx
    xor     %rax, %rax
.pf_check_done:
    cmp     %r15, %rcx
    jge     .pf_check_done_end
    lea     proc_remaining(%rip), %rdi
    addq    (%rdi, %rcx, 8), %rax
    inc     %rcx
    jmp     .pf_check_done

.pf_check_done_end:
    cmp     $0, %rax
    je      .pf_done

    # Select: three-level comparison (priority -> remaining -> index)
    movq    $999999, %r8            # best priority (sentinel)
    movq    $-1, %r9                # best index
    movq    $999999, %r10           # best remaining
    xor     %rcx, %rcx

.pf_select:
    cmp     %r15, %rcx
    jge     .pf_select_done

    # Skip completed processes
    lea     proc_remaining(%rip), %rdi
    movq    (%rdi, %rcx, 8), %rax
    cmp     $0, %rax
    jle     .pf_select_next

    # Skip unarrived processes
    lea     proc_arrival(%rip), %rdi
    movq    (%rdi, %rcx, 8), %rbx
    cmp     %rbp, %rbx
    jg      .pf_select_next

    # Level 1: compare priority
    lea     proc_priority(%rip), %rdi
    movq    (%rdi, %rcx, 8), %r11
    cmp     %r8, %r11
    jg      .pf_select_next         # worse priority -> skip
    jl      .pf_new_best            # better priority -> new best

    # Level 2: equal priority -> compare remaining time (shorter wins)
    lea     proc_remaining(%rip), %rdi
    movq    (%rdi, %rcx, 8), %rax
    cmp     %r10, %rax
    jg      .pf_select_next         # longer remaining -> skip
    jl      .pf_new_best            # shorter remaining -> new best

    # Level 3: equal priority and remaining -> keep first (lower index)
    jmp     .pf_select_next

.pf_new_best:
    mov     %r11, %r8               # update best priority
    mov     %rcx, %r9               # update best index
    lea     proc_remaining(%rip), %rdi
    movq    (%rdi, %rcx, 8), %r10   # update best remaining

.pf_select_next:
    inc     %rcx
    jmp     .pf_select

.pf_select_done:
    # No arrived process: emit idle cycle
    cmp     $-1, %r9
    jne     .pf_run_cycle

    mov     $'X', %al
    call    append_output
    inc     %rbp
    jmp     .pf_cycle

.pf_run_cycle:
    # Run selected process for one cycle
    lea     proc_id(%rip), %rdi
    movq    (%rdi, %r9, 8), %rax
    call    append_output

    lea     proc_remaining(%rip), %rdi
    decq    (%rdi, %r9, 8)

    inc     %rbp
    jmp     .pf_cycle

.pf_done:
    pop     %rbp
    pop     %r15
    pop     %r14
    pop     %r13
    pop     %r12
    pop     %rbx
    jmp     do_output

##############################################################################
# RR - Round Robin
#
# All processes arrive at time 0 and are enqueued in input order.
# Each process gets min(remaining, quantum) active cycles per turn.
# If the process finishes before the quantum expires, the remaining
# cycles in that quantum slot are padded with idle ('X') — the CPU
# does NOT switch to the next process mid-quantum.
# If the process still has remaining time after a full quantum, it is
# re-enqueued at the back of the queue.
#
# Uses an array-based circular queue (max 10 entries) with head/tail
# pointers wrapping at index 10.
#
# Register usage:
#   r15 = process count      r14 = quantum value
#   r12 = current process index (dequeued)
#   r13 = remaining time after this slot
#   r8  = active cycles this slot
#   rbp = process ID character
#   rbx = queue head/tail index
##############################################################################
run_rr:
    push    %rbx
    push    %r12
    push    %r13
    push    %r14
    push    %r15
    push    %rbp

    lea     proc_count(%rip), %rdi
    movq    (%rdi), %r15

    lea     quantum_val(%rip), %rdi
    movq    (%rdi), %r14

    # Initialize circular queue: head=0, count=n
    # Tail wraps to 0 when n==10 (all slots occupied)
    lea     rr_head(%rip), %rdi
    movq    $0, (%rdi)
    mov     %r15, %rax
    cmp     $10, %rax
    jl      .rr_tail_init_ok
    xor     %rax, %rax
.rr_tail_init_ok:
    lea     rr_tail(%rip), %rdi
    movq    %rax, (%rdi)
    lea     rr_count(%rip), %rdi
    movq    %r15, (%rdi)

    # Fill queue with process indices 0..n-1
    xor     %rcx, %rcx
.rr_init_queue:
    cmp     %r15, %rcx
    jge     .rr_main_loop
    lea     rr_queue(%rip), %rdi
    movq    %rcx, (%rdi, %rcx, 8)
    inc     %rcx
    jmp     .rr_init_queue

.rr_main_loop:
    # Terminate when queue is empty
    lea     rr_count(%rip), %rdi
    movq    (%rdi), %rax
    cmp     $0, %rax
    je      .rr_done

    # --- Dequeue front process ---
    lea     rr_head(%rip), %rdi
    movq    (%rdi), %rbx
    lea     rr_queue(%rip), %rdi
    movq    (%rdi, %rbx, 8), %r12   # r12 = process index

    # Advance head with circular wrap (mod 10)
    inc     %rbx
    cmp     $10, %rbx
    jl      .rr_head_ok
    xor     %rbx, %rbx
.rr_head_ok:
    lea     rr_head(%rip), %rdi
    movq    %rbx, (%rdi)
    lea     rr_count(%rip), %rdi
    decq    (%rdi)

    # Load process state
    lea     proc_remaining(%rip), %rdi
    movq    (%rdi, %r12, 8), %r13   # r13 = remaining burst
    lea     proc_id(%rip), %rdi
    movq    (%rdi, %r12, 8), %rbp   # rbp = process ID character

    # --- Compute active cycles: min(remaining, quantum) ---
    mov     %r13, %rcx
    cmp     %r14, %rcx
    jle     .rr_active_set
    mov     %r14, %rcx              # cap at quantum
.rr_active_set:
    mov     %rcx, %r8               # r8 = active cycles this slot
    sub     %rcx, %r13              # r13 = remaining after this slot

    # --- Output active cycles ---
.rr_active_loop:
    cmp     $0, %rcx
    jle     .rr_idle_pad
    push    %rcx
    mov     %bpl, %al
    call    append_output
    pop     %rcx
    dec     %rcx
    jmp     .rr_active_loop

.rr_idle_pad:
    # If process finished (remaining == 0), pad rest of quantum with 'X'
    cmp     $0, %r13
    jne     .rr_no_pad

    # Idle padding: quantum - active_cycles = number of X's to emit
    mov     %r14, %rcx
    sub     %r8, %rcx
.rr_pad_loop:
    cmp     $0, %rcx
    jle     .rr_after_pad
    push    %rcx
    mov     $'X', %al
    call    append_output
    pop     %rcx
    dec     %rcx
    jmp     .rr_pad_loop

.rr_after_pad:
    # Process done — do not re-enqueue
    lea     proc_remaining(%rip), %rdi
    movq    $0, (%rdi, %r12, 8)
    jmp     .rr_main_loop

.rr_no_pad:
    # Process still has remaining time — update and re-enqueue at tail
    lea     proc_remaining(%rip), %rdi
    movq    %r13, (%rdi, %r12, 8)

    lea     rr_tail(%rip), %rdi
    movq    (%rdi), %rbx
    lea     rr_queue(%rip), %rdi
    movq    %r12, (%rdi, %rbx, 8)

    # Advance tail with circular wrap (mod 10)
    inc     %rbx
    cmp     $10, %rbx
    jl      .rr_tail_ok
    xor     %rbx, %rbx
.rr_tail_ok:
    lea     rr_tail(%rip), %rdi
    movq    %rbx, (%rdi)
    lea     rr_count(%rip), %rdi
    incq    (%rdi)

    jmp     .rr_main_loop

.rr_done:
    pop     %rbp
    pop     %r15
    pop     %r14
    pop     %r13
    pop     %r12
    pop     %rbx
    jmp     do_output