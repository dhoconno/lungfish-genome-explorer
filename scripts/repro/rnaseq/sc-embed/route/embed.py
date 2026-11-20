# SPDX-License-Identifier: MIT
# embed.py: the cell-map route of Lungfish Genome Explorer (LGE), sub-phase 5.5 (C1 to C11).
# Run only as `env -i <PATH HOME TMPDIR + the 5.5 C2 variables> python -s -B -P embed.py ...`
# (ruling C2-PYFLAGS). The guard below refuses any other form. The CLI ships this file byte
# for byte (5.5 C3). It copies no GPL source and calls leidenalg and python-igraph only as
# installed packages of the managed environment (5.5 C9).
import os
import sys


def _guard():
    """Ruling C2-PYFLAGS item 3. One stderr line naming the failed check, then exit 3."""
    def fail(check):
        sys.stderr.write("embed.py: guard failed: %s\n" % check)
        sys.exit(3)
    if sys.version_info < (3, 11):
        fail("sys.version_info >= (3, 11)")
    f = sys.flags
    probe = None
    if "--allow-hash-seed" in sys.argv:
        i = sys.argv.index("--allow-hash-seed")
        probe = sys.argv[i + 1] if i + 1 < len(sys.argv) else ""
    if probe is None:
        if f.hash_randomization != 0:
            fail("sys.flags.hash_randomization == 0 (PYTHONHASHSEED=0)")
    elif not (probe.isdigit() and probe != "0" and os.environ.get("PYTHONHASHSEED") == probe):
        fail("--allow-hash-seed N names the nonzero PYTHONHASHSEED in the environment")
    if f.no_user_site != 1:
        fail("sys.flags.no_user_site == 1 (-s)")
    if f.safe_path is not True:
        fail("sys.flags.safe_path is True (-P)")
    if f.dont_write_bytecode != 1:
        fail("sys.flags.dont_write_bytecode == 1 (-B)")
    if f.ignore_environment != 0:
        fail("sys.flags.ignore_environment == 0 (no -E)")
    if f.isolated != 0:
        fail("sys.flags.isolated == 0 (no -I)")
    extra = sorted(k for k in os.environ if k.startswith("PYTHON") and k != "PYTHONHASHSEED")
    if extra:
        fail("no PYTHON* variable but PYTHONHASHSEED (found %s)" % ",".join(extra))
    prefix = os.path.realpath(sys.prefix)
    for p in sys.path:
        r = os.path.realpath(p)
        if r != prefix and not r.startswith(prefix + os.sep):
            fail("every sys.path entry under sys.prefix (found %s)" % p)
    return probe


HASH_PROBE = _guard()
ENV_NAMES = sorted(os.environ)  # the variables the interpreter saw, before any library sets its own

import argparse  # noqa: E402
import gzip  # noqa: E402
import hashlib  # noqa: E402
import importlib.metadata as md  # noqa: E402
import json  # noqa: E402
import platform  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402

# The locked versions of the 5.5 C10 line, asserted before any of them is imported.
LOCKED = {
    "scanpy": "1.11.5", "anndata": "0.12.19", "numpy": "2.4.6", "scipy": "1.17.1",
    "numba": "0.68.1", "llvmlite": "0.50.0", "scikit-learn": "1.9.1", "pynndescent": "0.7.0",
    "umap-learn": "0.6.0", "igraph": "1.0.0", "leidenalg": "0.12.0", "pandas": "2.3.3",
    "threadpoolctl": "3.8.0", "joblib": "1.6.0", "natsort": "8.4.0",
}
LOCKED_PYTHON = "3.11.18"
LOCKED_OPENBLAS = "0.3.34"
C2_THREADS = ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
              "VECLIB_MAXIMUM_THREADS", "NUMBA_NUM_THREADS")
C2_CACHES = ("NUMBA_CACHE_DIR", "MPLCONFIGDIR", "XDG_CACHE_HOME")
STEPS = [
    "read: scipy.io.mmread of each sample's matrix, transposed to cells by features, in argv order",
    "cast X to float32 after the read (normalize_total casts only integer input)",
    "keep features of the named feature type, then sc.pp.filter_genes(min_cells)",
    "sc.pp.normalize_total(target_sum), whose total sums only the kept genes",
    "sc.pp.log1p",
    "sc.pp.highly_variable_genes(n_top_genes, flavor)",
    "subset to the variable genes before scale (sc.pp.scale has no gene mask)",
    "sc.pp.scale(max_value), zero-centred",
    "sc.pp.pca(n_comps, svd_solver, random_state)",
    "sc.pp.neighbors(n_neighbors, n_pcs, metric, method umap, random_state, transformer)",
    "sc.tl.leiden(flavor, resolution, n_iterations, directed, use_weights, random_state)",
    "sc.tl.umap(min_dist, spread, init_pos, random_state, maxiter), legacy layout",
]
T0 = time.perf_counter()
TIMES = {}


def die(msg):
    sys.stderr.write("embed.py: %s\n" % msg)
    sys.exit(2)


def say(msg):
    sys.stderr.write("embed.py: [%s] %s\n" % (time.strftime("%H:%M:%S"), msg))
    sys.stderr.flush()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def file_fact(path):
    return {"name": os.path.basename(path), "sha256": sha256(path), "bytes": os.path.getsize(path)}


def open_input(path, gz):
    if not os.path.isfile(path):
        die("no such input file: %s" % path)
    with open(path, "rb") as fh:
        is_gz = fh.read(2) == b"\x1f\x8b"
    if is_gz != gz:
        die("%s: the gzip state is given as %s, but the file is %sgzipped"
            % (path, "true" if gz else "false", "" if is_gz else "not "))
    return gzip.open(path, "rb") if gz else open(path, "rb")


def read_lines(path, gz):
    with open_input(path, gz) as fh:
        return [ln.decode("utf-8").rstrip("\r\n") for ln in fh]


def boolean(s):
    if s not in ("true", "false"):
        raise argparse.ArgumentTypeError("give true or false")
    return s == "true"


def parse_args(argv):
    p = argparse.ArgumentParser(prog="embed.py", description="LGE cell-map route (5.5 C1 to C11).")
    a = p.add_argument
    a("--sample", action="append", required=True, help="sample name, once per matrix entry")
    a("--matrix", action="append", required=True)
    a("--features", action="append", required=True)
    a("--barcodes", action="append", required=True)
    a("--gzip", action="append", required=True, type=boolean)
    a("--cells", required=True, help="'all', or a TSV with header sample<TAB>barcode naming the cells kept")
    a("--out", required=True, help="new or empty output folder")
    a("--lock", required=True, help="the explicit lock the environment was built from")
    a("--threads", required=True, type=int)
    a("--feature-type", required=True)
    a("--min-cells", required=True, type=int)
    a("--target-sum", required=True, type=float)
    a("--n-top-genes", required=True, type=int)
    a("--hvg-flavor", required=True, choices=["seurat"])
    a("--scale-max", required=True, type=float)
    a("--n-comps", required=True, type=int)
    a("--svd-solver", required=True, choices=["arpack"])
    a("--pca-seed", required=True, type=int)
    a("--n-neighbors", required=True, type=int)
    a("--n-pcs", required=True, type=int)
    a("--knn-metric", required=True, choices=["euclidean"])
    a("--knn-transformer", required=True, choices=["sklearn", "scanpy-default"],
      help="sklearn is the route (exact, brute). scanpy-default is a report-only probe")
    a("--neighbors-seed", required=True, type=int)
    a("--leiden-flavor", required=True, choices=["leidenalg", "igraph"])
    a("--leiden-iterations", required=True, type=int)
    a("--leiden-directed", required=True, type=boolean)
    a("--leiden-use-weights", required=True, type=boolean)
    a("--resolution", required=True, type=float)
    a("--leiden-seed", required=True, type=int)
    a("--umap-min-dist", required=True, type=float)
    a("--umap-spread", required=True, type=float)
    a("--umap-init", required=True, choices=["spectral"])
    a("--umap-maxiter", required=True, choices=["umap-default"],
      help="umap-learn's epochs: 500 at 10,000 cells or fewer, else 200")
    a("--umap-seed", required=True, type=int)
    a("--allow-hash-seed", default=None, help="report-only hash-order probe, never the route")
    args = p.parse_args(argv)
    n = len(args.sample)
    if not (len(args.matrix) == len(args.features) == len(args.barcodes) == len(args.gzip) == n):
        die("give --sample, --matrix, --features, --barcodes and --gzip once for each matrix entry")
    if len(set(args.sample)) != n:
        die("each --sample name must be different")
    if args.threads < 1:
        die("--threads must be 1 or more")
    if args.leiden_flavor == "igraph" and args.leiden_directed:
        die("the igraph flavor of Leiden takes only --leiden-directed false")
    return args


def check_environment(args):
    bad = [k for k in C2_THREADS if os.environ.get(k) != str(args.threads)]
    if bad:
        die("each thread variable must equal --threads %d (not so for %s)" % (args.threads, ",".join(bad)))
    prefix = os.path.realpath(sys.prefix)
    for k in C2_CACHES:
        v = os.environ.get(k, "")
        if not v or not os.path.isdir(v):
            die("%s must name an existing temporary folder" % k)
        if os.path.realpath(v).startswith(prefix + os.sep):
            die("%s must not lie inside the environment" % k)
    sk = sorted(k for k in os.environ if k.startswith("SKLEARN_"))
    if sk:
        die("no SKLEARN_* variable may reach the route (found %s)" % ",".join(sk))


def check_lock(lock):
    """The environment holds exactly the lock's packages, each with the lock's md5."""
    want = {}
    with open(lock) as fh:
        for ln in fh:
            ln = ln.strip()
            if not ln.startswith("http"):
                continue
            url, _, md5 = ln.partition("#")
            base = url.rsplit("/", 1)[1]
            for ext in (".conda", ".tar.bz2"):
                if base.endswith(ext):
                    base = base[: -len(ext)]
            want[base] = md5
    meta = os.path.join(sys.prefix, "conda-meta")
    have, pkgs = {}, []
    for n in sorted(os.listdir(meta)):
        if n.endswith(".json"):
            with open(os.path.join(meta, n)) as fh:
                j = json.load(fh)
            have[n[:-5]] = j.get("md5", "")
            pkgs.append((j["name"], j["version"], j["build"], j.get("channel", "")))
    missing = sorted(set(want) - set(have))
    extra = sorted(set(have) - set(want))
    if missing or extra:
        die("the environment differs from the lock: %d missing (%s), %d extra (%s)"
            % (len(missing), ",".join(missing[:3]), len(extra), ",".join(extra[:3])))
    wrong = sorted(k for k in want if want[k] and have[k] and want[k] != have[k])
    if wrong:
        die("md5 differs from the lock for %d packages (%s)" % (len(wrong), ",".join(wrong[:3])))
    return len(want), sorted(pkgs)


def check_versions():
    if platform.python_version() != LOCKED_PYTHON:
        die("python %s, the lock holds %s" % (platform.python_version(), LOCKED_PYTHON))
    got = {}
    for name, v in LOCKED.items():
        try:
            got[name] = md.version(name)
        except md.PackageNotFoundError:
            die("package %s is missing, the lock holds %s" % (name, v))
        if got[name] != v:
            die("package %s is %s, the lock holds %s" % (name, got[name], v))
    return got


def cpu_model():
    try:
        r = subprocess.run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"],
                           capture_output=True, text=True, check=True, env={})
        return r.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        try:
            with open("/proc/cpuinfo") as fh:
                for ln in fh:
                    if ln.startswith("model name"):
                        return ln.split(":", 1)[1].strip()
        except OSError:
            pass
    return "unknown"


def f32(v):
    """Round-trip float32 text, the shortest form that reads back to the same float (5.5 L4)."""
    import numpy as np
    return np.format_float_positional(np.float32(v), unique=True, trim="-")


def read_inputs(args):
    import numpy as np
    import scipy.io
    import scipy.sparse as sp
    blocks, samples, barcodes, facts = [], [], [], []
    feat_ref = names = None
    entries = 0
    for s, mpath, fpath, bpath, gz in zip(args.sample, args.matrix, args.features, args.barcodes, args.gzip):
        feats = [ln.split("\t") for ln in read_lines(fpath, gz) if ln]
        bcs = [ln for ln in read_lines(bpath, gz) if ln]
        key = [(r[0], r[2] if len(r) > 2 else None) for r in feats]
        if feat_ref is None:
            feat_ref, names = key, [r[1] if len(r) > 1 else r[0] for r in feats]
        elif key != feat_ref:
            die("sample %s lists other features than sample %s, and every matrix entry must share one feature list"
                % (s, args.sample[0]))
        with open_input(mpath, gz) as fh:
            m = scipy.io.mmread(fh)
        if m.shape != (len(feats), len(bcs)):
            die("sample %s: the matrix is %d by %d, but there are %d features and %d barcodes"
                % (s, m.shape[0], m.shape[1], len(feats), len(bcs)))
        entries += int(m.nnz)
        blocks.append(sp.csr_matrix(m.T))
        samples += [s] * len(bcs)
        barcodes += bcs
        facts.append({"sample": s, "gzip": gz, "matrix": file_fact(mpath),
                      "features": file_fact(fpath), "barcodes": file_fact(bpath),
                      "cells": len(bcs), "features_listed": len(feats), "stored_entries": int(m.nnz)})
        del m
    X = blocks[0] if len(blocks) == 1 else sp.vstack(blocks, format="csr")
    del blocks
    pairs = list(zip(samples, barcodes))
    if len(set(pairs)) != len(pairs):
        die("%d (sample, barcode) pairs repeat" % (len(pairs) - len(set(pairs))))
    if args.cells != "all":
        want = []
        with open(args.cells) as fh:
            head = fh.readline().rstrip("\r\n").split("\t")
            if head[:2] != ["sample", "barcode"]:
                die("--cells: the first line must be sample<TAB>barcode")
            for ln in fh:
                r = ln.rstrip("\r\n").split("\t")
                if len(r) >= 2:
                    want.append((r[0], r[1]))
        ws = set(want)
        if len(ws) != len(want):
            die("--cells repeats %d cells" % (len(want) - len(ws)))
        missing = len(ws - set(pairs))
        if missing:
            die("--cells names %d cells that no matrix entry holds" % missing)
        keep_rows = np.array([p in ws for p in pairs])
        X = X[keep_rows]
        samples = [s for s, k in zip(samples, keep_rows) if k]
        barcodes = [b for b, k in zip(barcodes, keep_rows) if k]
    types = [t for _, t in feat_ref]
    if all(t is None for t in types):
        ge = np.ones(len(types), dtype=bool)
        type_note = "the features file has no type column, so every feature counts as %s" % args.feature_type
    else:
        ge = np.array([t == args.feature_type for t in types])
        type_note = "kept %d of %d features of type %s" % (int(ge.sum()), len(types), args.feature_type)
    if not ge.any():
        die("no feature has type %s" % args.feature_type)
    ids = [i for (i, _), k in zip(feat_ref, ge) if k]
    nms = [n for n, k in zip(names, ge) if k]
    return X, ge, ids, nms, samples, barcodes, facts, entries, type_note


def lap(name, t):
    TIMES[name] = round(time.perf_counter() - t, 3)
    return time.perf_counter()


def plain(v):
    import numpy as np
    if isinstance(v, (bool, int, str)) or v is None:
        return v
    if isinstance(v, (float, np.floating)):
        return f32(v)
    if isinstance(v, np.integer):
        return int(v)
    return str(v)


def main(argv):
    args = parse_args(argv)
    if args.allow_hash_seed != HASH_PROBE:
        die("--allow-hash-seed was read differently by the guard")
    check_environment(args)
    npk, pkgs = check_lock(args.lock)
    versions = check_versions()
    if os.path.exists(args.out) and os.listdir(args.out):
        die("--out %s is not empty" % args.out)
    os.makedirs(args.out, exist_ok=True)
    say("guard passed, the environment equals the lock (%d packages), versions locked" % npk)

    import numpy as np
    from threadpoolctl import threadpool_info, threadpool_limits
    import anndata as ad
    import scanpy as sc
    import numba
    import llvmlite.binding as llvm
    sc.settings.n_jobs = 1
    sc.settings.verbosity = 1
    blas = [d for d in threadpool_info() if d.get("internal_api") == "openblas"]
    if not blas or blas[0].get("version") != LOCKED_OPENBLAS:
        die("OpenBLAS %s, the lock holds %s" % (blas[0].get("version") if blas else "missing", LOCKED_OPENBLAS))

    with threadpool_limits(limits=args.threads):
        t = time.perf_counter()
        X, ge, ids, nms, samples, barcodes, facts, entries, type_note = read_inputs(args)
        t = lap("read", t)
        say("read %d cells by %d features, %d stored entries" % (X.shape[0], X.shape[1], entries))
        X = X.astype(np.float32)
        X = X[:, ge].tocsr()
        a = ad.AnnData(X=X)
        del X
        a.obs_names = ["c%d" % i for i in range(a.n_obs)]
        a.var_names = ids
        a.var["name"] = nms
        n_cells = a.n_obs
        sc.pp.filter_genes(a, min_cells=args.min_cells)
        genes_kept = int(a.n_vars)
        t = lap("filter", t)
        sc.pp.normalize_total(a, target_sum=args.target_sum)
        sc.pp.log1p(a)
        t = lap("normalise", t)
        sc.pp.highly_variable_genes(a, n_top_genes=args.n_top_genes, flavor=args.hvg_flavor)
        a = a[:, a.var["highly_variable"].values].copy()
        t = lap("hvg", t)
        sc.pp.scale(a, max_value=args.scale_max)
        t = lap("scale", t)
        say("%d genes kept, %d variable, scaled" % (genes_kept, a.n_vars))
        sc.pp.pca(a, n_comps=args.n_comps, svd_solver=args.svd_solver, random_state=args.pca_seed)
        t = lap("pca", t)
        nkw = dict(n_neighbors=args.n_neighbors, n_pcs=args.n_pcs, use_rep="X_pca", metric=args.knn_metric,
                   method="umap", random_state=args.neighbors_seed)
        if args.knn_transformer == "sklearn":
            nkw["transformer"] = "sklearn"
        sc.pp.neighbors(a, **nkw)
        t = lap("neighbors", t)
        say("neighbors done (%s)" % args.knn_transformer)
        sc.tl.leiden(a, resolution=args.resolution, random_state=args.leiden_seed,
                     n_iterations=args.leiden_iterations, flavor=args.leiden_flavor,
                     directed=args.leiden_directed, use_weights=args.leiden_use_weights, key_added="leiden")
        t = lap("leiden", t)
        sc.tl.umap(a, min_dist=args.umap_min_dist, spread=args.umap_spread, init_pos=args.umap_init,
                   random_state=args.umap_seed, maxiter=None)
        t = lap("umap", t)

    emb = a.obsm["X_umap"]
    umap_dtype = str(emb.dtype)
    emb = emb.astype(np.float32)
    lab = a.obs["leiden"].astype(int).to_numpy()
    out = args.out
    with open(os.path.join(out, "cells.tsv"), "w", newline="\n") as fh:
        fh.write("sample\tbarcode\tx\ty\tcluster\n")
        for i in range(n_cells):
            fh.write("%s\t%s\t%s\t%s\t%d\n" % (samples[i], barcodes[i], f32(emb[i, 0]), f32(emb[i, 1]), lab[i]))
    with open(os.path.join(out, "variable_genes.tsv"), "w", newline="\n") as fh:
        fh.write("feature_id\tname\n")
        for gid, nm in zip(a.var_names, a.var["name"]):
            fh.write("%s\t%s\n" % (gid, nm))
    with open(os.path.join(out, "pca_variance_ratio.tsv"), "w", newline="\n") as fh:
        fh.write("pc\tvariance_ratio\n")
        for i, v in enumerate(a.uns["pca"]["variance_ratio"]):
            fh.write("%d\t%s\n" % (i + 1, f32(v)))
    with open(os.path.join(out, "packages.tsv"), "w", newline="\n") as fh:
        fh.write("name\tversion\tbuild\tchannel\n")
        for r in pkgs:
            fh.write("\t".join(r) + "\n")

    f = sys.flags
    prefix = os.path.realpath(sys.prefix)
    script = os.path.realpath(__file__)
    flags = []
    for x in list(getattr(sys, "orig_argv", []))[1:]:
        if not x.startswith("-"):
            break
        flags.append(x)
    counts = {str(int(k)): int(v) for k, v in zip(*np.unique(lab, return_counts=True))}
    rec = {
        "route": "LGE cell-map route, sub-phase 5.5",
        "script": {"name": os.path.basename(script), "sha256": sha256(script)},
        "guard": "passed" if HASH_PROBE is None else
                 "passed with --allow-hash-seed %s (report-only hash-order probe, not the route)" % HASH_PROBE,
        "interpreter": {
            "flags": flags,
            "sys_flags": {k: int(getattr(f, k)) for k in ("hash_randomization", "no_user_site", "safe_path",
                                                          "dont_write_bytecode", "ignore_environment", "isolated")},
            "version": sys.version,
            "path": [os.path.relpath(os.path.realpath(p), prefix) for p in sys.path],
        },
        "environment": {
            "names": ENV_NAMES,
            "values": dict([(k, os.environ[k]) for k in C2_THREADS + ("PYTHONHASHSEED",)]
                           + [(k, "<run temporary folder>") for k in C2_CACHES]),
            "scanpy settings.n_jobs": sc.settings.n_jobs,
        },
        "host": {
            "cpu_model": cpu_model(),
            "platform": platform.platform(),
            "machine": platform.machine(),
            "numba_cpu_name": numba.config.CPU_NAME or llvm.get_host_cpu_name(),
            "openblas": {k: blas[0].get(k) for k in ("version", "architecture", "threading_layer")},
            "threadpools": sorted("%s %s" % (d.get("internal_api"), d.get("version") if isinstance(d.get("version"), str)
                                             else "(no version string)") for d in threadpool_info()),
        },
        "lock": {"name": os.path.basename(args.lock), "sha256": sha256(args.lock), "packages": npk,
                 "check": "every lock package is installed with the lock's md5 and nothing else is"},
        "versions": dict(versions, python=platform.python_version(), openblas=blas[0].get("version")),
        "inputs": facts,
        "cells": "all" if args.cells == "all" else file_fact(args.cells),
        "counts": {"cells": n_cells, "stored_entries_read": entries, "features_of_type": int(ge.sum()),
                   "genes_kept": genes_kept, "variable_genes": int(a.n_vars), "clusters": len(counts),
                   "cluster_sizes": counts},
        "feature_type": type_note,
        "threads": args.threads,
        "seeds": {"pca": args.pca_seed, "neighbors": args.neighbors_seed, "leiden": args.leiden_seed,
                  "umap": args.umap_seed},
        "parameters": {k: plain(v) for k, v in sorted(vars(args).items())
                       if k not in ("sample", "matrix", "features", "barcodes", "gzip", "cells", "out", "lock")},
        "steps": STEPS,
        "normalised_total": "normalize_total sums only the kept genes. It is not the Gene Expression colour of 5.5 G1",
        "knn": ("kNN: exact, brute, transformer=sklearn" if args.knn_transformer == "sklearn" else
                "kNN: scanpy default for %d cells (report-only probe, not the route)" % n_cells),
        "neighbors_params": {k: plain(v) for k, v in sorted(a.uns["neighbors"]["params"].items())},
        "leiden_params": {k: plain(v) for k, v in sorted(a.uns["leiden"]["params"].items())},
        "umap": {"compatibility_layout": True, "optimizer": "compatibility",
                 "params": {k: plain(v) for k, v in sorted(a.uns["umap"]["params"].items())},
                 "n_epochs": 500 if n_cells <= 10000 else 200, "dtype_returned": umap_dtype},
        "outputs": {n: sha256(os.path.join(out, n)) for n in ("cells.tsv", "variable_genes.tsv",
                                                               "pca_variance_ratio.tsv", "packages.tsv")},
    }
    with open(os.path.join(out, "record.json"), "w", newline="\n") as fh:
        json.dump(rec, fh, indent=1, sort_keys=True, ensure_ascii=True)
        fh.write("\n")
    TIMES["total"] = round(time.perf_counter() - T0, 3)
    with open(os.path.join(out, "timings.json"), "w", newline="\n") as fh:
        json.dump(TIMES, fh, indent=1, sort_keys=True)
        fh.write("\n")
    print("embed.py: %d cells, %d clusters, %s" % (n_cells, len(counts), rec["knn"]))
    print("embed.py: wrote %s" % out)


if __name__ == "__main__":
    main(sys.argv[1:])
