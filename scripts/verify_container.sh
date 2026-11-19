#!/usr/bin/env bash
set -euo pipefail

echo "=== 1. Dynamic Library & MPI Linkage Check ==="
LDD_OUT=$(ldd /opt/gromacs/bin/gmx_mpi)
echo "$LDD_OUT" | grep -E "libcp2k|libtblite|libmpi|libgomp" || true

if echo "$LDD_OUT" | grep -q "not found"; then
    echo "ERROR: Unresolved shared libraries detected in gmx_mpi!"
    echo "$LDD_OUT" | grep "not found"
    exit 1
fi

for lib in libcp2k.so libtblite.so libmpi.so libgomp.so; do
    if ! echo "$LDD_OUT" | grep -q "$lib"; then
        echo "ERROR: Expected library $lib not linked in gmx_mpi!"
        exit 1
    fi
done

MPI_COUNT=$(echo "$LDD_OUT" | grep -c "libmpi\.so" || true)
if [ "$MPI_COUNT" -ne 1 ]; then
    echo "ERROR: Expected exactly 1 libmpi.so linkage, found $MPI_COUNT"
    exit 1
fi
echo "PASS: All required shared libraries resolved with single MPI linkage."

echo "=== 2. PLUMED Integration Check ==="
MDRUN_HELP=$(gmx_mpi mdrun -h -hidden 2>&1 || true)
if ! echo "$MDRUN_HELP" | grep -qi "plumed"; then
    echo "ERROR: -plumed flag not found in gmx_mpi mdrun -h -hidden"
    exit 1
fi
echo "PASS: PLUMED integration active in gmx_mpi."

echo "=== 3. Python / ASE / mpi4py Check ==="
mpirun --allow-run-as-root -np 2 python3 -c "from mpi4py import MPI; import ase; print(f'rank={MPI.COMM_WORLD.Get_rank()} size={MPI.COMM_WORLD.Get_size()} ase={ase.__version__}')"
echo "PASS: mpi4py + ASE verified across 2 MPI ranks."

echo "=== 4. End-to-End QM/MM (GFN2-xTB via tblite) + PLUMED Smoke Test ==="
WORKDIR=$(mktemp -d /tmp/qmmm_smoke_XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

# Build a minimal 2-water system (1 QM water + 1 MM water) in a 2.0 nm box
cat <<'EOF' > box.gro
Two waters for QM/MM smoke test
    6
    1SOL     OW    1   1.000   1.000   1.000
    1SOL    HW1    2   1.076   1.059   1.000
    1SOL    HW2    3   0.924   1.059   1.000
    2SOL     OW    4   1.400   1.000   1.000
    2SOL    HW1    5   1.476   1.059   1.000
    2SOL    HW2    6   1.324   1.059   1.000
   2.00000   2.00000   2.00000
EOF

cat <<'EOF' > topol.top
#include "amber99sb-ildn.ff/forcefield.itp"
#include "amber99sb-ildn.ff/tip3p.itp"

[ system ]
QM/MM Water Smoke Test

[ molecules ]
SOL 2
EOF

# Index file defining QMatoms (first water: atoms 1, 2, 3)
cat <<'EOF' > index.ndx
[ System ]
1 2 3 4 5 6
[ QMatoms ]
1 2 3
EOF

# GROMACS MDP with CP2K QM/MM enabled (2 MD steps)
cat <<'EOF' > qmmm.mdp
integrator               = md
dt                       = 0.0005
nsteps                   = 2
nstlog                   = 1
nstenergy                = 1
cutoff-scheme            = Verlet
coulombtype              = PME
rcoulomb                 = 0.9
rvdw                     = 0.9
pbc                      = xyz

qmmm-cp2k-active         = true
qmmm-cp2k-qmgroup        = QMatoms
qmmm-cp2k-qmmethod       = INPUT
qmmm-cp2k-qmfilenames    = qmmm_run
EOF

# CP2K input using tblite GFN2-xTB
cat <<'EOF' > cp2k_gfn2.inp
&GLOBAL
  PROJECT smoke_qmmm
  RUN_TYPE ENERGY_FORCE
  PRINT_LEVEL LOW
&END GLOBAL
&FORCE_EVAL
  METHOD QMMM
  &DFT
    CHARGE 0
    MULTIPLICITY 1
    &QS
      METHOD xTB
      &XTB
        &TBLITE T
          METHOD GFN2
        &END TBLITE
      &END XTB
    &END QS
    &SCF
      SCF_GUESS ATOMIC
      EPS_SCF 1.0E-5
      MAX_SCF 50
    &END SCF
    &POISSON
      PERIODIC XYZ
      POISSON_SOLVER PERIODIC
      &EWALD
        EWALD_TYPE SPME
        GMAX 25
      &END EWALD
    &END POISSON
  &END DFT
  &MM
    &FORCEFIELD
      DO_NONBONDED FALSE
    &END FORCEFIELD
    &POISSON
      &EWALD
        EWALD_TYPE SPME
        GMAX 25
      &END EWALD
    &END POISSON
  &END MM
  &QMMM
    ECOUPL COULOMB
    USE_GEEP_LIB 12
    &CELL
      ABC 20.0 20.0 20.0
    &END CELL
    &QM_KIND O
      MM_INDEX 1
    &END QM_KIND
    &QM_KIND H
      MM_INDEX 2 3
    &END QM_KIND
  &END QMMM
  &SUBSYS
    &CELL
      ABC 20.0 20.0 20.0
    &END CELL
    &TOPOLOGY
      COORD_FILE_NAME qmmm_input.pdb
      COORD_FILE_FORMAT PDB
      CHARGE_EXTENDED TRUE
      CONN_FILE_FORMAT OFF
    &END TOPOLOGY
  &END SUBSYS
&END FORCE_EVAL
EOF

# PLUMED input monitoring O-O distance
cat <<'EOF' > plumed.dat
d1: DISTANCE ATOMS=1,4
PRINT ARG=d1 STRIDE=1 FILE=COLVAR
EOF

mkdir -p topol qmmm_run
gmx_mpi grompp -f qmmm.mdp -c box.gro -p topol.top -n index.ndx -qmi cp2k_gfn2.inp -o topol.tpr -maxwarn 2
if ! OMP_NUM_THREADS=2 /opt/bin/gmx_isolated.sh mdrun -s topol.tpr -plumed plumed.dat -ntomp 2; then
    echo "=== mdrun failed; diagnostic logs ==="
    find . -maxdepth 2 -type f
    for f in md.log $(find . -maxdepth 2 \( -name "*.out" -o -name "qmmm_run.inp" \) -type f); do
        if [ -f "$f" ]; then
            echo "--- $f (tail) ---"
            tail -n 70 "$f"
        fi
    done
    exit 1
fi

if [ ! -s COLVAR ]; then
    echo "ERROR: PLUMED COLVAR file was not generated!"
    exit 1
fi
echo "COLVAR output:"
cat COLVAR
echo "PASS: End-to-end QM/MM (GFN2-xTB via tblite) + PLUMED smoke test succeeded!"
