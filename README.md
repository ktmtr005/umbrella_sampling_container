# QM/MM (ASE + GROMACS + CP2K/tblite + PLUMED) コンテナ

Rocky Linux 9 をベースに、統一された OpenMPI スタック上で **ASE**・**GROMACS**・**CP2K (tblite による GFN2-xTB 対応)**・**PLUMED** を統合した、QM/MM NEB および Umbrella Sampling 向けの Docker コンテナ環境です。

## 構成ソフトウェアとデフォルトバージョン

| コンポーネント | デフォルトバージョン (`ARG`) | 備考 |
| :--- | :--- | :--- |
| Base OS | `rockylinux:9` | Python 3.11 |
| OpenMPI | `4.1.6` (`OPENMPI_VERSION`) | 内部 PMIx, hwloc/libevent 外部リンク |
| ScaLAPACK | `2.2.0` (`SCALAPACK_VERSION`) | OpenBLAS + LAPACK |
| tblite | `0.4.0` (`TBLITE_VERSION`) | GFN2-xTB エンジン (OpenMP) |
| DBCSR | `2.8.0` (`DBCSR_VERSION`) | MPI + OpenMP |
| CP2K | `2025.2` (`CP2K_VERSION`) | `libcp2k.so` + `cp2k.psmp` (tblite 有効) |
| PLUMED | `2.9.2` (`PLUMED_VERSION`) | MPI 対応, 全モジュール有効 |
| GROMACS | `2024.2` (`GROMACS_VERSION`) | PLUMED パッチ適用, `GMX_MPI=ON`, `GMX_CP2K=ON` |
| Python パッケージ | - | `mpi4py` (コンテナ内 `mpicc` でビルド), `numpy`, `scipy`, `ase` |

## リポジトリ構成

- [`Dockerfile`](Dockerfile) — コンテナイメージのビルド定義
- [`scripts/test_container.sh`](scripts/test_container.sh) — ホスト側からコンテナを起動して検証を実行するテストスクリプト
- [`scripts/verify_container.sh`](scripts/verify_container.sh) — コンテナ内で実行される統合検証スイート
- [`scripts/gmx_isolated.sh`](scripts/gmx_isolated.sh) — MPI 並列の Python ドライバ（ASE NEB 等）から子プロセスとして `gmx_mpi` を安全に起動するためのラッパー
- [`templates/cp2k_gfn2_qmmm.inp`](templates/cp2k_gfn2_qmmm.inp) — GROMACS-CP2K (tblite GFN2-xTB) 用の参照入力テンプレート

---

## Docker コンテナのビルド方法

リポジトリのルートディレクトリで `docker build` を実行します。`scripts/test_container.sh` のデフォルトタグである `ktmtrtr/qmmm-neb-us:latest` を付ける例は以下の通りです。

```bash
docker build -t ktmtrtr/qmmm-neb-us:latest .
```

> [!NOTE]
> OpenMPI・ScaLAPACK・tblite・DBCSR・CP2K・PLUMED・GROMACS をすべてソースからコンパイルするため、ビルドには相応の時間・CPU リソース・メモリ・ディスク容量が必要です。

### バージョンを変更してビルドする

`Dockerfile` 内の `ARG` を `--build-arg` で上書きできます。

```bash
docker build \
  --build-arg CP2K_VERSION=2025.2 \
  --build-arg GROMACS_VERSION=2024.2 \
  -t my-qmmm:custom .
```

---

## テスト用スクリプトの使い方

ビルドしたイメージが正しく動作するか確認するために、ホスト側ランナー [`scripts/test_container.sh`](scripts/test_container.sh) とコンテナ内検証スクリプト [`scripts/verify_container.sh`](scripts/verify_container.sh) が用意されています。

### 1. ホストからテストを実行する (`scripts/test_container.sh`)

デフォルトのイメージタグ (`ktmtrtr/qmmm-neb-us:latest`) をテストする場合:

```bash
./scripts/test_container.sh
```

任意のイメージタグを指定してテストする場合（引数または環境変数 `IMAGE` を使用）:

```bash
# 引数で指定
./scripts/test_container.sh my-qmmm:custom

# 環境変数で指定
IMAGE=my-qmmm:custom ./scripts/test_container.sh
```

ヘルプの表示:

```bash
./scripts/test_container.sh --help
```

> [!TIP]
> `test_container.sh` はホスト上の `scripts/verify_container.sh` と `scripts/gmx_isolated.sh` をコンテナ内の `/opt/bin/` へ読み取り専用 (`:ro`) でマウントして実行します。そのため、検証スクリプトを編集した際にイメージを再ビルドせずテストできます。

### 2. コンテナ内で直接テストを実行する (`verify_container.sh`)

コンテナ起動時に `/opt/bin/verify_container.sh` として同梱されているため、コンテナ内からも直接実行できます。

```bash
docker run --rm ktmtrtr/qmmm-neb-us:latest /opt/bin/verify_container.sh
```

### 検証項目

`verify_container.sh` は以下の 4 項目を順に検証し、すべて成功すると終了コード `0` で終了します。

1. **動的ライブラリと MPI リンクの確認**
   `ldd /opt/gromacs/bin/gmx_mpi` を確認し、`libcp2k.so`・`libtblite.so`・`libmpi.so`・`libgomp.so` が解決されていること、および `libmpi.so` が単一リンクであることを検証します。
2. **PLUMED 統合の確認**
   `gmx_mpi mdrun -h -hidden` の出力に `-plumed` オプションが含まれることを確認します。
3. **Python / ASE / mpi4py の動作確認**
   `mpirun --allow-run-as-root -np 2` で 2 ランクの MPI プロセスを起動し、`mpi4py` と `ase` がインポート・通信できることを確認します。
4. **End-to-End QM/MM (GFN2-xTB) + PLUMED スモークテスト**
   一時ディレクトリ上に 2 つの水分子（QM 1 分子 + MM 1 分子）の系を作成し、`gmx_mpi grompp` と `/opt/bin/gmx_isolated.sh mdrun -plumed plumed.dat -ntomp 2` を 2 ステップ実行して、`COLVAR` ファイルが生成されることを確認します。

---

## コンテナの基本的な使い方

カレントディレクトリをコンテナ内の `/workspace` にマウントして対話シェルを起動する例:

```bash
docker run --rm -it -v "$PWD:/workspace" ktmtrtr/qmmm-neb-us:latest
```

### 同梱ユーティリティ・テンプレート

- **`/opt/bin/gmx_isolated.sh`**
  `mpi4py` を用いた並列 Python スクリプト（ASE NEB など）からサブプロセスとして `gmx_mpi` を呼び出す際、親プロセスの OpenMPI / PMIx 環境変数（`OMPI_COMM_WORLD_*`, `PMIX_*`）を `unset` してから `gmx_mpi` を実行するラッパーです。
- **`/opt/templates/cp2k_gfn2_qmmm.inp`**
  GROMACS-CP2K 連携で `tblite` (GFN2-xTB) と Ewald 静電埋め込み (`&QMMM`) を使用する際の参照入力ファイルです。
