#!/usr/bin/env python3
"""
analisar.py - estatisticas, tabelas e graficos do Trabalho 1.

Uso:
    analisar.py <csv> [<csv2> ...] [-o DIR]

Le os resultados.csv gerados por run_experimento.sh, cujas colunas sao
    ambiente,N,rep,tentativa,bytes,dt_s,mbps,valido,bytes_por_cliente,
    retrans,retrans_servidor
e considera so as execucoes validas (valido == 1) e fora do aquecimento
(rep >= 1). As linhas sao agrupadas pela coluna "ambiente": dois CSVs do
mesmo ambiente (duas rodadas) viram uma serie so; ambientes diferentes
(local e rede) viram series separadas e geram tambem a figura comparativa.

Por serie e por N: maximo, media, desvio-padrao amostral (n-1), meia-largura
do IC de 95% (t de Student), minimo, numero de execucoes validas, indice de
Jain medio e retransmissoes medias.

Saidas em DIR (padrao: diretorio do primeiro CSV):
    tabela_<amb>.csv   tabela_<amb>.tex
    throughput_<amb>.png / .pdf
    comparativo.png / .pdf          (so com duas ou mais series)

Depende so da biblioteca padrao e do matplotlib (pandas nao e usado; scipy
e usado para o t de Student se estiver instalado, senao vale a tabela
embutida).
"""

import argparse
import csv
import math
import os
import statistics
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.ticker import FuncFormatter, MaxNLocator  # noqa: E402

# t de Student bicaudal, 95% (t_{0,975; gl}). Para gl fora da tabela usa o
# maior gl tabelado que nao passa de gl (valor um pouco maior: conservador).
T95 = {
    1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
    8: 2.306, 9: 2.262, 10: 2.228, 11: 2.201, 12: 2.179, 13: 2.160,
    14: 2.145, 15: 2.131, 16: 2.120, 17: 2.110, 18: 2.101, 19: 2.093,
    20: 2.086, 21: 2.080, 22: 2.074, 23: 2.069, 24: 2.064, 25: 2.060,
    26: 2.056, 27: 2.052, 28: 2.048, 29: 2.045, 30: 2.042, 40: 2.021,
    50: 2.009, 60: 2.000, 80: 1.990, 100: 1.984, 120: 1.980,
}

try:
    from scipy.stats import t as _t_dist  # type: ignore

    def t95(gl):
        return float(_t_dist.ppf(0.975, gl))

    FONTE_T = "scipy"
except ImportError:
    def t95(gl):
        if gl in T95:
            return T95[gl]
        menores = [k for k in T95 if k <= gl]
        return T95[max(menores)] if menores else T95[1]

    FONTE_T = "tabela embutida"


def jain(valores):
    """Indice de justica de Jain: (soma x)^2 / (n * soma x^2)."""
    n = len(valores)
    soma2 = sum(x * x for x in valores)
    if n == 0 or soma2 == 0:
        return float("nan")
    return sum(valores) ** 2 / (n * soma2)


def ler_csvs(caminhos):
    """Devolve {ambiente: {N: [execucao, ...]}} so com execucoes validas."""
    series = {}
    descartadas = 0
    for caminho in caminhos:
        with open(caminho, newline="") as f:
            for lin in csv.DictReader(f):
                try:
                    valido = int(lin["valido"])
                    rep = int(lin["rep"])
                    n = int(lin["N"])
                    mbps = float(lin["mbps"])
                except (KeyError, ValueError):
                    descartadas += 1
                    continue
                if valido != 1 or rep < 1:
                    descartadas += 1
                    continue
                por_cli = [float(x) for x in
                           lin.get("bytes_por_cliente", "").split(";") if x]
                retr = lin.get("retrans", "")
                series.setdefault(lin["ambiente"], {}).setdefault(n, []).append({
                    "rep": rep,
                    "mbps": mbps,
                    "jain": jain(por_cli) if por_cli else float("nan"),
                    "retrans": float(retr) if retr not in ("", None) else float("nan"),
                })
    return series, descartadas


def media_sem_nan(xs):
    xs = [x for x in xs if not math.isnan(x)]
    return statistics.fmean(xs) if xs else float("nan")


def estatisticas(por_n):
    linhas = []
    for n in sorted(por_n):
        v = [e["mbps"] for e in por_n[n]]
        k = len(v)
        media = statistics.fmean(v)
        dp = statistics.stdev(v) if k >= 2 else float("nan")
        ic = t95(k - 1) * dp / math.sqrt(k) if k >= 2 else float("nan")
        linhas.append({
            "N": n,
            "max": max(v),
            "media": media,
            "dp": dp,
            "ic95": ic,
            "min": min(v),
            "n_validas": k,
            "jain": media_sem_nan([e["jain"] for e in por_n[n]]),
            "retrans": media_sem_nan([e["retrans"] for e in por_n[n]]),
        })
    return linhas


COLUNAS = ["N", "max", "media", "dp", "ic95", "min", "n_validas", "jain",
           "retrans"]


def gravar_csv(linhas, caminho):
    with open(caminho, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["N", "max_mbps", "media_mbps", "dp_mbps", "ic95_mbps",
                    "min_mbps", "n_validas", "jain_medio", "retrans_medio"])
        for l in linhas:
            w.writerow([l["N"]] + [
                "" if isinstance(l[c], float) and math.isnan(l[c])
                else (f"{l[c]:.3f}" if isinstance(l[c], float) else l[c])
                for c in COLUNAS[1:]])


def num_br(x, casas=1, milhar="\\,"):
    """Numero no formato brasileiro: virgula decimal e separador de milhar."""
    if isinstance(x, float) and math.isnan(x):
        return "--"
    s = f"{x:,.{casas}f}"
    return s.replace(",", "\x00").replace(".", ",").replace("\x00", milhar)


def gravar_tex(linhas, caminho, ambiente):
    """Tabela LaTeX simples (tabular + \\hline), sem pacotes extras: o
    template SBC nao carrega booktabs. Legenda acima, como no template."""
    rot = ambiente.replace("_", "\\_")
    with open(caminho, "w") as f:
        f.write("% Gerado por scripts/analisar.py; valores em Mbps.\n")
        f.write("\\begin{table}[ht]\n\\centering\n")
        f.write(f"\\caption{{Throughput agregado por número de clientes "
                f"({rot}), em Mbps. IC95: meia-largura do intervalo de "
                f"confiança de 95\\% (t de Student).}}\n")
        f.write(f"\\label{{tab:throughput-{ambiente}}}\n")
        f.write("\\small\n\\begin{tabular}{rrrrrrrr}\n\\hline\n")
        f.write("N & Máximo & Média & DP & IC95 ($\\pm$) & Mínimo & "
                "Válidas & Jain \\\\\n\\hline\n")
        for l in linhas:
            f.write(" & ".join([
                str(l["N"]), num_br(l["max"]), num_br(l["media"]),
                num_br(l["dp"]), num_br(l["ic95"]), num_br(l["min"]),
                str(l["n_validas"]), num_br(l["jain"], 3),
            ]) + " \\\\\n")
        f.write("\\hline\n\\end{tabular}\n\\end{table}\n")


def formatar_eixo(ax, log=False):
    ax.set_xlabel("Número de clientes simultâneos (N)")
    ax.set_ylabel("Throughput agregado (Mbps)")
    ax.xaxis.set_major_locator(MaxNLocator(integer=True))
    if not log:
        ax.yaxis.set_major_formatter(
            FuncFormatter(lambda v, _: num_br(v, 0, ".")))
    ax.grid(True, which="major", alpha=0.4)


def desenhar(ax, linhas, rotulo="", cor=None):
    ns = [l["N"] for l in linhas]
    medias = [l["media"] for l in linhas]
    ics = [0.0 if math.isnan(l["ic95"]) else l["ic95"] for l in linhas]
    maximos = [l["max"] for l in linhas]
    sufixo = f" ({rotulo})" if rotulo else ""
    eb = ax.errorbar(ns, medias, yerr=ics, fmt="o-", capsize=4, color=cor,
                     label=f"Média ± IC95%{sufixo}")
    cor = eb[0].get_color()
    ax.plot(ns, maximos, "s--", color=cor, alpha=0.7, markerfacecolor="none",
            label=f"Máximo{sufixo}")


def eixo_n(ax, todas):
    ns = sorted({l["N"] for linhas in todas for l in linhas})
    ax.set_xticks(ns)
    ax.set_xlim(min(ns) - 0.5, max(ns) + 0.5)


def salvar(fig, base):
    fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(f"{base}.{ext}", dpi=200)
    plt.close(fig)


def imprimir(linhas, ambiente):
    print(f"\n== {ambiente} (Mbps; IC95 = meia-largura, t: {FONTE_T}) ==")
    print(f"{'N':>3} {'max':>11} {'media':>11} {'dp':>9} {'ic95':>9} "
          f"{'min':>11} {'n':>3} {'jain':>6} {'retrans':>9}")
    for l in linhas:
        print(f"{l['N']:>3} {l['max']:>11.1f} {l['media']:>11.1f} "
              f"{l['dp']:>9.1f} {l['ic95']:>9.1f} {l['min']:>11.1f} "
              f"{l['n_validas']:>3} {l['jain']:>6.3f} {l['retrans']:>9.0f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("csv", nargs="+", help="resultados.csv do run_experimento.sh")
    ap.add_argument("-o", "--saida", help="diretorio de saida")
    args = ap.parse_args()

    for c in args.csv:
        if not os.path.isfile(c):
            sys.exit(f"Arquivo nao encontrado: {c}")

    saida = args.saida or os.path.dirname(os.path.abspath(args.csv[0]))
    os.makedirs(saida, exist_ok=True)

    series, descartadas = ler_csvs(args.csv)
    if not series:
        sys.exit("Nenhuma execucao valida (valido=1, rep>=1) nos CSVs.")

    print(f"Linhas ignoradas (invalidas, aquecimento ou malformadas): "
          f"{descartadas}")

    tabelas = {}
    for amb in sorted(series):
        linhas = estatisticas(series[amb])
        tabelas[amb] = linhas
        imprimir(linhas, amb)
        gravar_csv(linhas, os.path.join(saida, f"tabela_{amb}.csv"))
        gravar_tex(linhas, os.path.join(saida, f"tabela_{amb}.tex"), amb)

        fig, ax = plt.subplots(figsize=(6.4, 4.0))
        desenhar(ax, linhas)
        formatar_eixo(ax)
        eixo_n(ax, [linhas])
        ax.set_ylim(bottom=0)
        ax.legend(loc="best", fontsize=9)
        salvar(fig, os.path.join(saida, f"throughput_{amb}"))

    if len(tabelas) >= 2:
        # Local (dezenas de Gbps) e rede (~1 Gbps) diferem por uma ordem de
        # grandeza ou mais: escala logaritmica num unico painel.
        fig, ax = plt.subplots(figsize=(6.4, 4.2))
        for amb, linhas in tabelas.items():
            desenhar(ax, linhas, amb)
        ax.set_yscale("log")
        formatar_eixo(ax, log=True)
        ax.yaxis.set_major_formatter(
            FuncFormatter(lambda v, _: num_br(v, 0, ".")))
        ax.grid(True, which="minor", alpha=0.15)
        eixo_n(ax, list(tabelas.values()))
        ax.legend(loc="best", fontsize=8)
        salvar(fig, os.path.join(saida, "comparativo"))

    print(f"\nArquivos gravados em {saida}")


if __name__ == "__main__":
    main()
