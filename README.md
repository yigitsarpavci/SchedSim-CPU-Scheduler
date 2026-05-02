# SchedSim CPU Scheduler

SchedSim is a CPU scheduling simulator written entirely in x86-64 GNU
Assembly for Linux. It uses direct syscalls only and is built with GNU
`as` and `ld`.

## Supported Algorithms

- FCFS: First Come First Serve
- SJF: Shortest Job First
- SRTF: Shortest Remaining Time First
- PF: Priority First
- RR: Round Robin

Burst-0 processes are ignored during parsing, as clarified for this
assignment.

## Build and Run

```sh
make
./schedsim
```

## Test

Run the full local test flow:

```sh
make testgrade
```

`make grade` also runs the provided test cases before invoking the Python
grader.

The grader can also be invoked directly after generating outputs:

```sh
make testcases
python3 test/grader.py ./schedsim test-cases
```
