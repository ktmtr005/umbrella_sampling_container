---
name: hpc-qmmm-neb-us-container-builder
description: Builds an HPC-ready container (Docker/Apptainer) integrating ASE, GROMACS, CP2K (with tblite for GFN2-xTB), and PLUMED compiled against a unified OpenMPI stack for QM/MM NEB and Umbrella Sampling simulations.
---

# HPC QM/MM (ASE + GROMACS + CP2K/tblite + PLUMED) Container Builder

## 1. Objective & Scope
This skill defines the architectural requirements, dependency constraints, build sequence, and verification tests required for an AI agent to generate a production-ready HPC container (Dockerfile / Singularity / Apptainer `.def`) for QM/MM Nudged Elastic Band (NEB) and Umbrella Sampling (US) workflows.

### Core Software Stack
1. **MPI & Compiler Toolchain**: Single unified GCC toolchain + OpenMPI (strictly consistent across all compiled binaries and Python bindings).
2. **tblite**: Provides native `GFN2-xTB` and `GFN1-xTB` library APIs (`libtblite`).
3. **CP2K**: Compiled as a shared/static library (`libcp2k`) with `tblite` support enabled to act as the QM/MM engine inside GROMACS.
4. **PLUMED**: Compiled with OpenMPI support (`libplumedKernel.so`) for enhanced sampling and Path CV / Umbrella restraints.
5. **GROMACS**: Official release patched with PLUMED and linked against `libcp2k` and OpenMPI (`GMX_MPI=ON`, `GMX_THREAD_MPI=OFF`).
6. **Python / ASE**: Python environment with `numpy`, `scipy`, `ase`, and `mpi4py` compiled against the exact same OpenMPI `mpicc`.

---

## 2. Critical Architectural Constraints (Non-Negotiable)

- **Single MPI & OpenMP Runtime Rule**:
  - Every component (`tblite`, `CP2K`, `PLUMED`, `GROMACS`, `mpi4py`) MUST be compiled and linked against the **exact same OpenMPI installation and GCC/OpenMP runtime (`libgomp`)**.
  - Do NOT mix Conda-installed MPI binaries with system/source-compiled OpenMPI. Build `mpi4py` from source using `MPICC=$(which mpicc)`.
- **GFN2-xTB via `tblite` in CP2K**:
  - CP2K's native `METHOD xTB` defaults to GFN1-xTB parameters. To fulfill the GFN2-xTB requirement, CP2K MUST be compiled with `-D__TBLITE` (and linked to `libtblite`) so `METHOD TBLITE` / `METHOD GFN2` is available in `&QS`.
- **GROMACS MPI Configuration**:
  - GROMACS MUST be built with `-DGMX_MPI=ON` and `-DGMX_THREAD_MPI=OFF`.
  - GPU offloading (`-DGMX_GPU`) should default to `OFF` unless explicitly requested, as QM/MM SCF steps are CPU-bound and require clean OpenMP thread scaling.
- **HPC Hybrid MPI/OpenMP & Nested MPI Safety**:
  - `tblite` relies heavily on OpenMP (`OMP_NUM_THREADS`). The container environment must preserve OpenMP thread affinity and expose `PLUMED_KERNEL`.
  - Include a wrapper utility or documented execution pattern for ASE NEB (`mpi4py`) invoking `gmx_mpi` subprocesses so `OMPI_COMM_WORLD_*` / `PMIX_*` environment variables do not collide when spawning single-rank OpenMP-parallel GROMACS processes.

---

## 3. Recommended Version Matrix & Base Image

Use a stable Linux base image compatible with HPC host MPI binding (e.g., Ubuntu 22.04 LTS or Rocky Linux 8/9):

- **Base OS**: `ubuntu:22.04` (or `rockylinux:8`)
- **Compilers**: `gcc` / `g++` / `gfortran` (v11 or v12)
- **MPI**: `OpenMPI` (v4.1.x — widely compatible with HPC Slurm/PBS PMIx host interconnects)
- **Math Libraries**: `OpenBLAS` (OpenMP-enabled or serial; ensure thread-safety with `tblite`), `FFTW3`, `ScaLAPACK` (required by CP2K)
- **tblite**: `v0.3.0` or newer (built via CMake/Meson with `-Dopenmp=true`)
- **CP2K**: `v2024.1` or newer (supports `libcp2k` + `tblite` integration)
- **PLUMED**: `v2.9.x`
- **GROMACS**: `2023.x` or `2024.x` (verify compatibility with `plumed patch -p` and `libcp2k` API)
- **Python**: `3.10+` with `ase>=3.22.1`, `mpi4py` (source-built)

---

## 4. Mandatory Build Sequence (Dependency Order)

The agent MUST structure the container build layers in the following strict dependency order:

### Step 1: System Dependencies & OpenMPI
- Install build tools: `cmake`, `ninja-build`, `meson`, `pkg-config`, `git`, `wget`, `python3-dev`, `python3-pip`, `libopenblas-dev`, `liblapack-dev`, `libfftw3-dev`, `libscalapack-mpi-dev`, `libgsl-dev`, `zlib1g-dev`.
- Verify/build `OpenMPI` (with `--with-pmix` / `--with-slurm` if targeting Slurm HPCs) and export `PATH`, `LD_LIBRARY_PATH`, `CC=mpicc`, `CXX=mpicxx`, `FC=mpifort`.

### Step 2: Build `tblite` (GFN2-xTB Engine)
- Clone `tblite` repository.
- Configure and build shared libraries (`libtblite.so`) with OpenMP enabled:
  ```bash
  cmake -B _build -G Ninja \
    -DCMAKE_INSTALL_PREFIX=/opt/tblite \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DWITH_OpenMP=ON
  cmake --build _build
  cmake --install _build
  ```
- Export `PKG_CONFIG_PATH=/opt/tblite/lib/pkgconfig:$PKG_CONFIG_PATH` and `/opt/tblite/lib` to `LD_LIBRARY_PATH`.

### Step 3: Build `CP2K` (`libcp2k` with `tblite`)
- Clone `cp2k` repository (matching target version).
- Use CP2K's toolchain or CMake build system configured with:
  - OpenMPI (`mpifort`, `mpicxx`)
  - OpenBLAS, ScaLAPACK, FFTW3
  - `tblite` enabled (`--with-tblite=/opt/tblite` in toolchain or `-DCP2K_USE_TBLITE=ON` in CMake)
- Build **both** the executable (`cp2k.psmp`) and the shared library (`libcp2k.so`):
  ```bash
  # Example using CP2K CMake build
  cmake -B build -G Ninja \
    -DCMAKE_INSTALL_PREFIX=/opt/cp2k \
    -DCP2K_USE_MPI=ON \
    -DCP2K_USE_OPENMP=ON \
    -DCP2K_USE_TBLITE=ON \
    -DCP2K_BUILD_OPTIONS=psmp
  cmake --build build
  cmake --install build
  ```
- Verify `libcp2k.so` and `libcp2k.h` exist in `/opt/cp2k/lib` and `/opt/cp2k/include`.

### Step 4: Build `PLUMED`
- Download/clone `plumed2`.
- Configure with OpenMPI (`CXX=mpicxx CC=mpicc`) and install to `/opt/plumed`:
  ```bash
  ./configure --prefix=/opt/plumed --enable-mpi --enable-modules=all
  make -j$(nproc)
  make install
  ```
- Export `/opt/plumed/bin` to `PATH`, `/opt/plumed/lib` to `LD_LIBRARY_PATH`, and set `ENV PLUMED_KERNEL=/opt/plumed/lib/libplumedKernel.so`.

### Step 5: Patch & Build `GROMACS`
- Download/extract `gromacs` source.
- Apply PLUMED patch non-interactively:
  ```bash
  /opt/plumed/bin/plumed patch -p -e gromacs-<VERSION>
  ```
- Configure and build GROMACS with `libcp2k` and OpenMPI:
  ```bash
  cmake -B build -G Ninja \
    -DCMAKE_INSTALL_PREFIX=/opt/gromacs \
    -DCMAKE_C_COMPILER=mpicc \
    -DCMAKE_CXX_COMPILER=mpicxx \
    -DGMX_MPI=ON \
    -DGMX_THREAD_MPI=OFF \
    -DGMX_OPENMP=ON \
    -DGMX_GPU=OFF \
    -DGMX_CP2K=ON \
    -DCP2K_DIR=/opt/cp2k \
    -DGMX_FFT_LIBRARY=fftw3 \
    -DGMX_BLAS_USER=/usr/lib/x86_64-linux-gnu/libopenblas.so \
    -DGMX_LAPACK_USER=/usr/lib/x86_64-linux-gnu/liblapack.so
  cmake --build build
  cmake --install build
  ```
- Source `/opt/gromacs/bin/GMXRC` in container environment variables (`PATH`, `LD_LIBRARY_PATH`, `GMXLIB`).

### Step 6: Python Environment (`ASE` + `mpi4py`)
- Install `mpi4py` compiled strictly against the container's `mpicc`:
  ```bash
  MPICC=$(which mpicc) pip3 install --no-cache-dir --no-binary=mpi4py mpi4py
  pip3 install --no-cache-dir numpy scipy ase
  ```

---

## 5. Helper Utilities to Include in Container (`/opt/bin`)

The agent should generate and embed two helper files inside `/opt/bin` (and add `/opt/bin` to `PATH`):

1. **`/opt/bin/gmx_isolated.sh`**:
   A wrapper script for launching `gmx_mpi` as a subprocess from an MPI-parallelized ASE NEB Python script without MPI communicator pollution:
   ```bash
   #!/usr/bin/env bash
   # Unset parent OpenMPI / PMIx rank variables so child gmx_mpi initializes cleanly
   unset OMPI_COMM_WORLD_SIZE OMPI_COMM_WORLD_RANK OMPI_COMM_WORLD_LOCAL_RANK
   unset OMPI_COMM_WORLD_NODE_RANK OMPI_UNIVERSE_SIZE PMIX_RANK PMIX_NAMESPACE
   exec gmx_mpi "$@"
   ```
2. **`/opt/templates/cp2k_gfn2_qmmm.inp`**:
   A reference CP2K QM/MM input snippet demonstrating `METHOD TBLITE` with `METHOD GFN2` and Ewald electrostatic embedding (`&QMMM`).

---

## 6. Verification & Smoke Test Protocol

Before finalizing the container image, the agent MUST execute a multi-stage verification suite inside the built container:

1. **Dynamic Library & MPI Linkage Check**:
   - Run `ldd /opt/gromacs/bin/gmx_mpi` and verify that `libcp2k.so`, `libtblite.so`, `libmpi.so`, and `libgomp.so` resolve with zero `not found` entries and only one MPI implementation is linked.
2. **PLUMED Integration Check**:
   - Run `gmx_mpi mdrun -h | grep -i plumed` to confirm `-plumed` flag is active.
3. **Python / ASE / mpi4py Check**:
   - Run `mpirun --allow-run-as-root -np 2 python3 -c "from mpi4py import MPI; import ase; print(MPI.COMM_WORLD.Get_rank(), ase.__version__)"`.
4. **End-to-End QM/MM (GFN2-xTB) + PLUMED Smoke Test**:
   - Run a minimal 2-step QM/MM MD test (e.g., 1 QM water molecule + MM water box) invoking `gmx_mpi mdrun` with `qmmm-cp2k-active = true`, `METHOD TBLITE` (`METHOD GFN2`), and a dummy `plumed.dat` (`DISTANCE` + `PRINT`) to confirm SCF convergence via `tblite` and `COLVAR` output generation.

---

## 7. Spec-First Debugging Rule (Mandatory `docker run` Inspection)

When any build, linkage, CLI, or runtime error occurs, the agent MUST NOT guess or iterate blindly by trial-and-error. Before editing scripts, templates, or `Dockerfile`, inspect the **exact specification of the compiled binaries inside the container** using `docker run --rm <image> ...`:

1. **CP2K Input Schema & Keywords**:
   - Dump and query the compiled binary's actual XML input schema instead of assuming syntax across CP2K versions:
     ```bash
     docker run --rm <image> bash -c 'cd /tmp && cp2k.psmp --xml && grep -i -C 5 "<KEYWORD>" cp2k_input.xml'
     ```
   - Verify section hierarchy (e.g., `/FORCE_EVAL/QMMM/PERIODIC/POISSON/EWALD`), `SECTION_PARAMETERS` (`&TBLITE T` vs `GFN_TYPE`), and valid sub-keywords before modifying `.inp` templates.
2. **Compiled Flags, Patches & Shared Library Linkage**:
   - Inspect enabled features and libraries directly in the image:
     - `cp2k.psmp --version` (`cp2kflags` for `tblite`, `libdftd4`, etc.)
     - `ldd /opt/cp2k/lib/libcp2k.so` and `ldd /opt/gromacs/bin/gmx_mpi`
     - `ls -d /opt/plumed/lib/plumed/patches/*` (exact supported engine names)
3. **GROMACS CLI Options & `pipefail` Safety**:
   - Inspect hidden and standard flags via `gmx_mpi <cmd> -h -hidden` inside `docker run`.
   - Under `set -euo pipefail`, capture command output into a variable before running `grep -q` (to avoid `SIGPIPE` / exit code `141`).
4. **Runtime QM/MM Failure Logs**:
   - Always dump `md.log`, generated CP2K inputs (e.g., `qmmm_run.inp`), and `*.out` logs on failure before removing temporary work directories so the exact `[ABORT]` / `CPASSERT` file and line number are diagnosed in a single step.

---

## 8. HPC Deployment Notes (Apptainer / Singularity)

When generating an Apptainer/Singularity definition file (`.def`) or conversion instructions from Docker:
- Ensure `%environment` explicitly exports `PATH`, `LD_LIBRARY_PATH`, `PLUMED_KERNEL`, and `GMXDATA`.
- Document the hybrid execution pattern for users:
  - **Umbrella Sampling**: `mpirun -np <N_WINDOWS> apptainer exec container.sif gmx_mpi mdrun -ntomp <OMP_THREADS> -multidir win_* -s umbrella.tpr -plumed plumed.dat`
  - **ASE NEB**: Use `OMP_NUM_THREADS=<THREADS_PER_IMAGE>` and configure ASE's `Gromacs` calculator to invoke `gmx_isolated.sh`.