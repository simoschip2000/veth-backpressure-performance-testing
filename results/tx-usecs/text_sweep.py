#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Text table of veth BQL sweep results with optional net-next-main comparison.

Usage examples:
  # BQL sweep only
  ./text_sweep.py fq_codel/Simon/sweep.csv

  # With net-next-main stock comparison column
  ./text_sweep.py fq_codel/Simon/sweep.csv --compare net-next-main/Simon/sweep.csv

  # Custom nrules / tx-usecs selection
  ./text_sweep.py fq_codel/Simon/sweep.csv --nrules 0,100,1000,5000,10000 \\
      --tx-usecs 0,100,500,1000,10000

  # p99 RTT instead of average
  ./text_sweep.py fq_codel/Simon/sweep.csv --compare net-next-main/Simon/sweep.csv --p99
"""

import argparse
import os
import sys

import pandas as pd


# ---------------------------------------------------------------------------
# Formatters
# ---------------------------------------------------------------------------

def _fmt_pps(v):
    """Format pps: 2170963 -> '2.17M', 684412 -> '684K', 500 -> '500'."""
    if pd.isna(v):
        return "-"
    v = int(v)
    if v >= 1_000_000:
        return f"{v / 1e6:.2f}M"
    if v >= 1000:
        return f"{v // 1000}K"
    return str(v)


def _fmt_rtt(v):
    """Format RTT in ms with varying precision."""
    if pd.isna(v):
        return "-"
    if v < 1.0:
        return f"{v:.3f}"
    if v < 10.0:
        return f"{v:.2f}"
    return f"{v:.1f}"


# ---------------------------------------------------------------------------
# CSV loading
# ---------------------------------------------------------------------------

def _load_csv(path):
    cmdline = None
    with open(path) as f:
        first = f.readline()
        if first.startswith("#"):
            cmdline = first.lstrip("# ").strip()
    df = pd.read_csv(path, comment="#", skipinitialspace=True)
    df.columns = df.columns.str.strip()
    return df, cmdline


def load_sweep(path, need_p99=False):
    df, cmdline = _load_csv(path)
    required = ["tx_usecs", "nrules", "avg_pps", "avg_rtt_ms"]
    if need_p99:
        required.append("avg_p99_ms")
    for col in required:
        if col not in df.columns:
            sys.exit(f"sweep CSV missing column: {col}")
    return df, cmdline


def load_baseline(path, need_p99=False):
    """Load a baseline CSV (e.g. net-next-main).

    tx_usecs is ignored: if multiple rows exist per nrules they are averaged.
    Falls back to avg_rtt_ms when avg_p99_ms is absent.
    """
    df, cmdline = _load_csv(path)
    for col in ["nrules", "avg_pps", "avg_rtt_ms"]:
        if col not in df.columns:
            sys.exit(f"baseline CSV missing column: {col}")
    agg_cols = ["avg_pps", "avg_rtt_ms"]
    if "avg_p99_ms" in df.columns:
        agg_cols.append("avg_p99_ms")
    if "tx_usecs" in df.columns:
        df = df.groupby("nrules", as_index=False)[agg_cols].mean()
    return df, cmdline


# ---------------------------------------------------------------------------
# Table renderer
# ---------------------------------------------------------------------------

def _print_table(title, nr_vals, tx_vals, cell_fn, bl_fn=None):
    """Print a text table.

    Parameters
    ----------
    title    : table title string
    nr_vals  : sorted list of nrules row values
    tx_vals  : sorted list of tx_usecs column values
    cell_fn  : callable(nrules, tx_usecs) -> str  — BQL cell value
    bl_fn    : callable(nrules) -> str, or None   — stock/"compare" column
    """
    row_hdr_lbl = "nrules"
    col_headers = [f"{tu}us" for tu in tx_vals]
    row_strs = [str(nr) for nr in nr_vals]

    # Pre-compute all cells
    cells = [[cell_fn(nr, tu) for tu in tx_vals] for nr in nr_vals]
    bl_cells = [bl_fn(nr) for nr in nr_vals] if bl_fn is not None else None

    # Column widths
    row_w = max(len(row_hdr_lbl), max((len(r) for r in row_strs), default=0))
    col_ws = []
    for ci, hdr in enumerate(col_headers):
        w = len(hdr)
        for ri in range(len(nr_vals)):
            w = max(w, len(cells[ri][ci]))
        col_ws.append(w)
    bl_w = max(len("stock"), max((len(v) for v in bl_cells), default=0)) if bl_cells is not None else 0

    # Build header line
    hdr_line = f"{row_hdr_lbl:>{row_w}} |"
    for ci, hdr in enumerate(col_headers):
        hdr_line += f" {hdr:>{col_ws[ci]}} |"
    if bl_cells is not None:
        hdr_line += f"| {'stock':>{bl_w}}"

    # Build separator line (mirrors header widths exactly)
    sep = f"{'-' * row_w}-+"
    for w in col_ws:
        sep += f"{'-' * (w + 2)}+"
    if bl_cells is not None:
        sep += f"+{'-' * (bl_w + 1)}"

    print(f"\n{title}")
    print("=" * max(len(title), len(hdr_line)))
    print(hdr_line)
    print(sep)
    for ri, nr in enumerate(nr_vals):
        line = f"{row_strs[ri]:>{row_w}} |"
        for ci, w in enumerate(col_ws):
            line += f" {cells[ri][ci]:>{w}} |"
        if bl_cells is not None:
            line += f"| {bl_cells[ri]:>{bl_w}}"
        print(line)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Text table of veth BQL sweep results")
    parser.add_argument("csv",
                        help="sweep.csv produced by veth_bql_sweep.sh (BQL-on patch)")
    parser.add_argument("--compare", metavar="CSV",
                        help="net-next-main (stock) baseline CSV; shown as an extra "
                             "column to the right, ignoring its tx_usecs dimension")
    parser.add_argument("--p99", action="store_true",
                        help="show p99 ping RTT instead of average RTT")
    parser.add_argument("--tx-usecs", metavar="LIST", default="0,100,1000,10000",
                        help="comma-separated tx-usecs values to include "
                             "(default: 0,100,1000,10000)")
    parser.add_argument("--nrules", metavar="LIST", default="0,100,1000,10000",
                        help="comma-separated nrules values to include "
                             "(default: 0,100,1000,10000)")
    parser.add_argument("-o", "--outfile", metavar="FILE", default=None,
                        help="write output to FILE (default: text_sweep.txt "
                             "next to the input CSV)")
    args = parser.parse_args()

    outfile = args.outfile or os.path.join(
        os.path.dirname(os.path.abspath(args.csv)), "text_sweep.txt")

    tx_filter = [int(x) for x in args.tx_usecs.split(",")]
    nr_filter = [int(x) for x in args.nrules.split(",")]
    rtt_col = "avg_p99_ms" if args.p99 else "avg_rtt_ms"
    rtt_label = f"Ping RTT ms {'(p99)' if args.p99 else '(avg)'}"

    df, cmdline = load_sweep(args.csv, need_p99=args.p99)
    df = df[df["tx_usecs"].isin(tx_filter) & df["nrules"].isin(nr_filter)]

    # Keep only values that actually exist in the data (preserve requested order)
    tx_vals = [t for t in tx_filter if t in df["tx_usecs"].values]
    nr_vals = [n for n in nr_filter if n in df["nrules"].values]

    df_bl = None
    bl_rtt_col = rtt_col
    if args.compare:
        df_bl, bl_cmdline = load_baseline(args.compare, need_p99=args.p99)
        df_bl = df_bl[df_bl["nrules"].isin(nr_filter)]
        # Fall back gracefully when baseline lacks p99
        if args.p99 and "avg_p99_ms" not in df_bl.columns:
            bl_rtt_col = "avg_rtt_ms"

    # Print header comments
    if cmdline:
        print(f"# patch:  {cmdline}")
    if df_bl is not None and bl_cmdline:
        print(f"# stock:  {bl_cmdline}")

    # Cell accessor helpers
    def pps_cell(nr, tu):
        row = df[(df["nrules"] == nr) & (df["tx_usecs"] == tu)]
        return _fmt_pps(row.iloc[0]["avg_pps"]) if not row.empty else "-"

    def rtt_cell(nr, tu):
        row = df[(df["nrules"] == nr) & (df["tx_usecs"] == tu)]
        return _fmt_rtt(row.iloc[0][rtt_col]) if not row.empty else "-"

    def bl_pps(nr):
        row = df_bl[df_bl["nrules"] == nr]
        return _fmt_pps(row.iloc[0]["avg_pps"]) if not row.empty else "-"

    def bl_rtt(nr):
        row = df_bl[df_bl["nrules"] == nr]
        return _fmt_rtt(row.iloc[0][bl_rtt_col]) if not row.empty else "-"

    import io
    buf = io.StringIO()
    _real_stdout = sys.stdout

    class _Tee:
        def write(self, s):
            _real_stdout.write(s)
            buf.write(s)
        def flush(self):
            _real_stdout.flush()

    sys.stdout = _Tee()

    _print_table("Throughput (pps)", nr_vals, tx_vals, pps_cell,
                 bl_fn=bl_pps if df_bl is not None else None)
    print()
    _print_table(rtt_label, nr_vals, tx_vals, rtt_cell,
                 bl_fn=bl_rtt if df_bl is not None else None)
    print()

    sys.stdout = _real_stdout
    with open(outfile, "w") as f:
        f.write(buf.getvalue())
    print(f"saved {outfile}")


if __name__ == "__main__":
    main()
