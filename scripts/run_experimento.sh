#!/usr/bin/env bash
#
# run_experimento.sh - bateria de medicao do Trabalho 1 (throughput do chat).
#
# Modos:
#   local    servidor e clientes nesta maquina (IP padrao 127.0.0.2)
#   servidor lado servidor do experimento em rede: obedece aos pedidos do
#            lado "clientes" recebidos pela porta de controle (PORTA+1)
#   clientes lado clientes do experimento em rede: e o "mestre" da sequencia
#            N/rep; pede cada execucao ao servidor e dispara os N clientes
#
# Uso:
#   run_experimento.sh local    [opcoes] [ip=127.0.0.2]
#   run_experimento.sh servidor [opcoes]
#   run_experimento.sh clientes [opcoes] <ip_servidor>
#
# Opcoes (cada uma tambem pode vir de variavel de ambiente, entre colchetes):
#   -p PORTA     porta de dados do chat_server [PORTA=5000]
#   -c PORTA     porta de controle (modo rede) [PORTA_CTL=PORTA+1]
#   -w S         aquecimento descartado, em s [W=2]
#   -d S         janela medida, em s [D=10]
#   -m S         margem: cliente transmite W+D+M s [MARGEM=1]
#   -b BYTES     bloco do send() do cliente [BLOCO=65536]
#   -r REPS      repeticoes por N [REPS=10]
#   -k N         N minimo [N_MIN=1]
#   -n N         N maximo [N_MAX=10]
#   -A 0|1       faz a execucao de aquecimento (rep 0) [AQUEC=1]
#   -t TENT      tentativas por (N, rep) [MAX_TENT=3]
#   -P S         pausa entre execucoes [PAUSA=3]
#   -T S         tempo maximo para os N clientes conectarem [T_ACCEPT=20]
#   -a NOME      rotulo do ambiente [AMBIENTE=local | rede]
#   -o DIR       diretorio base da saida [SAIDA=resultados/<ambiente>]
#
# Sincronizacao no modo rede: o lado "clientes"
# decide a sequencia (inclusive as retentativas) e, para cada execucao, envia
# "RUN N rep tent W D ambiente" a porta de controle; o lado "servidor" responde
# "ACK" e sobe o chat_server com esse N. Os clientes repetem o connect ate o
# chat_server estar no ar, e a barreira GO do servidor alinha a transmissao.
# No fim, os clientes pedem "RES N rep tent" e recebem o codigo de saida e a
# linha CSV do servidor; assim os dois lados sempre concordam sobre a
# validade da execucao. "FIM" encerra o modo servidor. O lado servidor usa
# python3 so para escutar a porta de controle; o lado clientes usa
# /dev/tcp do bash.

set -u -o pipefail

DIR_SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DIR_TRAB=$(cd "$DIR_SCRIPT/.." && pwd)
BUILD=${BUILD:-$DIR_TRAB}
SERVIDOR_BIN=$BUILD/chat_server
CLIENTE_BIN=$BUILD/chat_client

PORTA=${PORTA:-5000}
PORTA_CTL=${PORTA_CTL:-}
W=${W:-2}
D=${D:-10}
MARGEM=${MARGEM:-1}
BLOCO=${BLOCO:-65536}
REPS=${REPS:-10}
N_MIN=${N_MIN:-1}
N_MAX=${N_MAX:-10}
AQUEC=${AQUEC:-1}
MAX_TENT=${MAX_TENT:-3}
PAUSA=${PAUSA:-3}
T_ACCEPT=${T_ACCEPT:-20}
AMBIENTE=${AMBIENTE:-}
SAIDA=${SAIDA:-}

# Tempo que o lado clientes espera o lado servidor aparecer (1o RUN) e
# tempo que o lado servidor espera o pedido RES depois de uma execucao.
T_ESPERA_SERVIDOR=${T_ESPERA_SERVIDOR:-900}
T_RES=${T_RES:-120}

# Espera do chat_server pelos clientes depois de t1 (ESPERA_FIM_S no .c)
# e do chat_client pelo fechamento (DRENO_TIMEOUT_S no .c).
ESPERA_FIM_S=5
DRENO_S=10

uso() {
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

erro() {
    echo "ERRO: $*" >&2
    exit 1
}

eh_inteiro() {
    [[ $1 =~ ^[0-9]+$ ]]
}

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------

[ $# -ge 1 ] || uso
MODO=$1
shift

case $MODO in
local|servidor|clientes) ;;
-h|--help|help) uso ;;
*) echo "Modo invalido: $MODO" >&2; uso ;;
esac

while getopts "p:c:w:d:m:b:r:k:n:A:t:P:T:a:o:h" opt; do
    case $opt in
    p) PORTA=$OPTARG ;;
    c) PORTA_CTL=$OPTARG ;;
    w) W=$OPTARG ;;
    d) D=$OPTARG ;;
    m) MARGEM=$OPTARG ;;
    b) BLOCO=$OPTARG ;;
    r) REPS=$OPTARG ;;
    k) N_MIN=$OPTARG ;;
    n) N_MAX=$OPTARG ;;
    A) AQUEC=$OPTARG ;;
    t) MAX_TENT=$OPTARG ;;
    P) PAUSA=$OPTARG ;;
    T) T_ACCEPT=$OPTARG ;;
    a) AMBIENTE=$OPTARG ;;
    o) SAIDA=$OPTARG ;;
    *) uso ;;
    esac
done
shift $((OPTIND - 1))

IP=""
case $MODO in
local)
    IP=${1:-127.0.0.2}
    [ $# -le 1 ] || uso
    ;;
servidor)
    [ $# -eq 0 ] || uso
    ;;
clientes)
    [ $# -eq 1 ] || { echo "Modo clientes exige <ip_servidor>." >&2; uso; }
    IP=$1
    ;;
esac

[ -n "$PORTA_CTL" ] || PORTA_CTL=$((PORTA + 1))

for v in PORTA PORTA_CTL W D MARGEM BLOCO REPS N_MIN N_MAX AQUEC MAX_TENT \
         PAUSA T_ACCEPT; do
    eh_inteiro "${!v}" || erro "$v deve ser inteiro (recebido '${!v}')."
done

[ "$PORTA" -ge 1 ] && [ "$PORTA" -le 65535 ] || erro "porta invalida."
[ "$PORTA_CTL" -ne "$PORTA" ] || erro "porta de controle igual a de dados."
[ "$D" -ge 1 ] || erro "D deve ser >= 1."
[ "$N_MIN" -ge 1 ] && [ "$N_MIN" -le "$N_MAX" ] && [ "$N_MAX" -le 100 ] ||
    erro "faixa de N invalida ($N_MIN..$N_MAX)."
[ "$REPS" -ge 1 ] && [ "$MAX_TENT" -ge 1 ] || erro "REPS e MAX_TENT >= 1."

if [ -n "$IP" ] && [[ ! $IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    erro "IP invalido: $IP (use IPv4 numerico)."
fi

if [ "$MODO" = local ] && [ "$IP" = 127.0.0.1 ]; then
    echo "AVISO: 127.0.0.1 no WSL2 espelhado passa pelo Windows;" \
         "use 127.0.0.2." >&2
fi

if [ -z "$AMBIENTE" ]; then
    if [ "$MODO" = local ]; then AMBIENTE=local; else AMBIENTE=rede; fi
fi
[[ $AMBIENTE =~ ^[A-Za-z0-9_.-]+$ ]] || erro "AMBIENTE so com [A-Za-z0-9_.-]."

[ "$MODO" = clientes ] || [ -x "$SERVIDOR_BIN" ] ||
    erro "$SERVIDOR_BIN nao existe; rode make."
[ "$MODO" = servidor ] || [ -x "$CLIENTE_BIN" ] ||
    erro "$CLIENTE_BIN nao existe; rode make."
[ "$MODO" != servidor ] || command -v python3 >/dev/null ||
    erro "o modo servidor precisa de python3 (porta de controle)."

# ---------------------------------------------------------------------------
# Diretorio da rodada (nunca sobrescreve: um diretorio por rodada)
# ---------------------------------------------------------------------------

[ -n "$SAIDA" ] || SAIDA=$DIR_TRAB/resultados/$AMBIENTE
CARIMBO=$(date +%Y%m%d-%H%M%S)
case $MODO in
local) RODADA=$SAIDA/$CARIMBO ;;
*) RODADA=$SAIDA/${CARIMBO}_$MODO ;;
esac
[ -e "$RODADA" ] && RODADA=${RODADA}_$$
mkdir -p "$RODADA/logs" || erro "nao consegui criar $RODADA."

CSV=$RODADA/resultados.csv
TENT_CSV=$RODADA/tentativas.csv
PROGRESSO=$RODADA/progresso.log

echo "ambiente,N,rep,tentativa,bytes,dt_s,mbps,valido,bytes_por_cliente,retrans,retrans_servidor" >"$CSV"
echo "inicio,N,rep,tentativa,codigo_servidor,clientes_com_erro,mbps,retrans,situacao" >"$TENT_CSV"

msg() {
    echo "$*" | tee -a "$PROGRESSO"
}

# ---------------------------------------------------------------------------
# Limpeza: nunca deixar chat_server, chat_client ou o escutador orfaos
# ---------------------------------------------------------------------------

descendentes() {
    local p
    for p in $(pgrep -P "$1" 2>/dev/null); do
        descendentes "$p"
        echo "$p"
    done
}

limpar() {
    trap - EXIT INT TERM
    local pids
    pids=$(descendentes $$)
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill -TERM $pids 2>/dev/null
        sleep 0.5
        # shellcheck disable=SC2086
        kill -KILL $pids 2>/dev/null
    fi
}

trap limpar EXIT
trap 'echo; msg "Interrompido."; exit 130' INT
trap 'msg "Encerrado (TERM)."; exit 143' TERM

# ---------------------------------------------------------------------------
# Auxiliares
# ---------------------------------------------------------------------------

# Valor absoluto de TcpRetransSegs (sem atualizar o historico do nstat).
retrans_atual() {
    local v
    v=$(nstat -asz TcpRetransSegs 2>/dev/null |
        awk '$1 == "TcpRetransSegs" { print $2 }')
    if [ -z "$v" ]; then
        # Alternativa sem nstat: coluna RetransSegs de /proc/net/snmp.
        v=$(awk '/^Tcp:/ { if (!h) { for (i = 1; i <= NF; i++)
                 if ($i == "RetransSegs") c = i; h = 1 }
                 else print $c }' /proc/net/snmp)
    fi
    echo "${v:-0}"
}

porta_escutando() {
    [ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ]
}

# Espera ate a porta $1 estar em LISTEN (ate $2 s).
esperar_escuta() {
    local fim=$((SECONDS + $2))
    while ! porta_escutando "$1"; do
        [ $SECONDS -lt $fim ] || return 1
        sleep 0.05
    done
}

# Espera a porta $1 ficar livre (ate $2 s).
esperar_porta_livre() {
    local fim=$((SECONDS + $2))
    while porta_escutando "$1"; do
        [ $SECONDS -lt $fim ] || return 1
        sleep 0.2
    done
}

fmt_tempo() {
    local s=$1
    printf '%dm%02ds' $((s / 60)) $((s % 60))
}

coletar_ambiente() {
    local arq=$1 ip_ref=$2 dev=""

    {
        echo "# Ambiente coletado por run_experimento.sh ($MODO) em $(date -Iseconds)"
        echo "### hostname"; hostname
        echo "### uname -a"; uname -a
        echo "### /etc/os-release"; cat /etc/os-release 2>/dev/null
        echo "### lscpu"; lscpu
        echo "### nproc"; nproc
        echo "### free -h"; free -h
        echo "### gcc --version"; gcc --version 2>&1 | head -n 1
        echo "### flags do Makefile"
        grep -E '^(CC|CFLAGS|LDFLAGS)' "$DIR_TRAB/Makefile" 2>/dev/null
        echo "### sha256 dos binarios"
        sha256sum "$SERVIDOR_BIN" "$CLIENTE_BIN" 2>/dev/null
        echo "### ip addr"; ip addr
        echo "### ip link"; ip link
        echo "### ip rule"; ip rule 2>&1
        if [ -n "$ip_ref" ]; then
            echo "### ip route get $ip_ref"; ip route get "$ip_ref" 2>&1
            dev=$(ip route get "$ip_ref" 2>/dev/null |
                  sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
        fi
        echo "### sysctl"
        sysctl net.ipv4.tcp_congestion_control net.ipv4.tcp_rmem \
               net.ipv4.tcp_wmem net.core.rmem_max net.core.wmem_max 2>&1
        if [ -n "$dev" ]; then
            echo "### interface $dev"
            echo "mtu: $(cat /sys/class/net/"$dev"/mtu 2>/dev/null)"
            echo "speed (Mb/s): $(cat /sys/class/net/"$dev"/speed 2>/dev/null)"
            if command -v ethtool >/dev/null; then
                echo "### ethtool $dev"; ethtool "$dev" 2>&1
            fi
        fi
    } >"$arq" 2>&1
}

# Acrescenta ao ambiente.txt, no modo servidor, a rota ate os clientes
# (o IP deles so e conhecido no primeiro pedido).
anexar_rota() {
    {
        echo "### ip route get $1 (clientes)"
        ip route get "$1" 2>&1
        local dev
        dev=$(ip route get "$1" 2>/dev/null |
              sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
        if [ -n "$dev" ]; then
            echo "mtu: $(cat /sys/class/net/"$dev"/mtu 2>/dev/null)"
            echo "speed (Mb/s): $(cat /sys/class/net/"$dev"/speed 2>/dev/null)"
            command -v ethtool >/dev/null && ethtool "$dev" 2>&1
        fi
    } >>"$RODADA/ambiente.txt"
}

salvar_parametros() {
    {
        echo "modo=$MODO"
        echo "ambiente=$AMBIENTE"
        echo "ip=$IP"
        echo "porta=$PORTA"
        echo "porta_ctl=$PORTA_CTL"
        echo "W=$W"
        echo "D=$D"
        echo "MARGEM=$MARGEM"
        echo "duracao_cliente=$((W + D + MARGEM))"
        echo "BLOCO=$BLOCO"
        echo "recv_servidor=65536 (fixo no chat_server.c)"
        echo "REPS=$REPS"
        echo "N=$N_MIN..$N_MAX"
        echo "AQUEC=$AQUEC"
        echo "MAX_TENT=$MAX_TENT"
        echo "PAUSA=$PAUSA"
        echo "T_ACCEPT=$T_ACCEPT"
        echo "inicio=$(date -Iseconds)"
    } >"$RODADA/parametros.txt"
}

# Prefixo dos logs de uma execucao.
prefixo_log() {
    printf '%s/logs/N%02d_r%02d_t%d' "$RODADA" "$1" "$2" "$3"
}

# ---------------------------------------------------------------------------
# Clientes (modos local e clientes)
# ---------------------------------------------------------------------------

# Roda um chat_client repetindo o connect enquanto ele for recusado (o
# servidor desta execucao ainda nao subiu). Qualquer outra falha encerra.
# A janela de retentativa e T_ACCEPT/2, para o servidor (que espera ate
# T_ACCEPT) ainda estar vivo quando o ultimo cliente chegar.
cliente_com_retry() {
    local ip=$1 porta=$2 nome=$3 log=$4
    local dur=$((W + D + MARGEM))
    local t_cli=$((T_ACCEPT + dur + DRENO_S + 5))
    local fim=$(($(date +%s) + T_ACCEPT / 2 + 1))
    local rc

    while :; do
        timeout -k 2 "$t_cli" "$CLIENTE_BIN" "$ip" "$porta" "$dur" \
            "$BLOCO" "$nome" 2>"$log.tmp"
        rc=$?
        cat "$log.tmp" >>"$log"
        if [ $rc -ne 0 ] && grep -q '^connect:' "$log.tmp" &&
           [ "$(date +%s)" -lt $fim ]; then
            sleep 0.2
            continue
        fi
        rm -f "$log.tmp"
        return $rc
    done
}

# Dispara N clientes em paralelo e espera todos. Resultado em CLI_ERROS
# (quantos sairam com codigo != 0) e CLI_BYTES (soma dos bytes enviados).
lancar_clientes() {
    local ip=$1 porta=$2 n=$3 rep=$4 tent=$5 pre=$6
    local i pids=() log
    CLI_ERROS=0
    CLI_BYTES=0

    for ((i = 1; i <= n; i++)); do
        log=${pre}_c$i.log
        : >"$log"
        cliente_com_retry "$ip" "$porta" "N${n}r${rep}t${tent}c$i" "$log" &
        pids+=($!)
    done

    for i in "${!pids[@]}"; do
        wait "${pids[$i]}" || CLI_ERROS=$((CLI_ERROS + 1))
    done

    # Junta os logs dos clientes num so arquivo.
    for ((i = 1; i <= n; i++)); do
        log=${pre}_c$i.log
        sed "s/^/[c$i] /" "$log"
        rm -f "$log"
    done >"${pre}_clientes.log"

    CLI_BYTES=$(awk -F, '/cliente,/ { s += $3 } END { printf "%.0f", s }' \
                "${pre}_clientes.log")
}

# ---------------------------------------------------------------------------
# Servidor (modos local e servidor)
# ---------------------------------------------------------------------------

# Sobe o chat_server em segundo plano com timeout. Define SRV_PID.
iniciar_servidor() {
    local n=$1 w=$2 d=$3 amb=$4 pre=$5
    local t_srv=$((T_ACCEPT + w + d + ESPERA_FIM_S + 10))

    if ! esperar_porta_livre "$PORTA" 10; then
        msg "AVISO: porta $PORTA ocupada por outro processo:"
        ss -Hltnp "sport = :$PORTA" | tee -a "$PROGRESSO"
        return 1
    fi

    # O timeout mata o servidor se ele ficar preso no accept.
    timeout -k 3 "$t_srv" "$SERVIDOR_BIN" -s "$PORTA" "$n" "$w" "$d" "$amb" \
        >"${pre}_servidor.csv" 2>"${pre}_servidor.log" &
    SRV_PID=$!

    if ! esperar_escuta "$PORTA" 5; then
        msg "AVISO: chat_server nao entrou em LISTEN em 5 s."
    fi
    return 0
}

# Espera o servidor; define SRV_COD (124 = morto por timeout) e SRV_LINHA.
esperar_servidor() {
    local pre=$1 prazo=${2:-0}

    # Com prazo (modo local, depois que todos os clientes terminaram): o
    # chat_server sai ate ESPERA_FIM_S apos t1; se ainda estiver vivo no
    # prazo, ficou preso no accept (algum cliente nao conectou) e e morto
    # agora, sem esperar o timeout inteiro.
    if [ "$prazo" -gt 0 ]; then
        local fim=$((SECONDS + prazo))
        while kill -0 "$SRV_PID" 2>/dev/null && [ $SECONDS -lt $fim ]; do
            sleep 0.2
        done
        if kill -0 "$SRV_PID" 2>/dev/null; then
            kill -TERM "$SRV_PID" 2>/dev/null
            echo "*** chat_server encerrado: clientes terminaram e ele nao saiu em ${prazo} s" \
                >>"${pre}_servidor.log"
        fi
    fi

    wait "$SRV_PID"
    SRV_COD=$?
    SRV_LINHA=$(grep -v '^rotulo,' "${pre}_servidor.csv" 2>/dev/null | tail -n 1)
    rm -f "${pre}_servidor.csv"
    [ $SRV_COD -ne 124 ] && [ $SRV_COD -ne 137 ] && [ $SRV_COD -ne 143 ] ||
        echo "*** chat_server morto por timeout (codigo $SRV_COD)" \
            >>"${pre}_servidor.log"
}

situacao_de() {
    case $1 in
    0) echo valida ;;
    2) echo invalida ;;
    124|137|143) echo timeout ;;
    *) echo erro ;;
    esac
}

# Grava a linha do servidor no CSV, inserindo rep/tentativa e retrans.
gravar_csv() {
    local linha=$1 rep=$2 tent=$3 retr=$4 retr_srv=$5
    [ -n "$linha" ] || return 0
    local rot n bytes dt mbps valido bpc
    IFS=, read -r rot n bytes dt mbps valido bpc <<<"$linha"
    echo "$rot,$n,$rep,$tent,$bytes,$dt,$mbps,$valido,$bpc,$retr,$retr_srv" >>"$CSV"
}

mbps_de() {
    local linha=$1
    [ -n "$linha" ] || { echo "-"; return; }
    echo "$linha" | cut -d, -f5
}

# ---------------------------------------------------------------------------
# Porta de controle (modo rede)
# ---------------------------------------------------------------------------

# Escutador de uma conexao: aceita, le uma linha, responde $2 e imprime
# "<ip_do_par> <linha>". Conexoes sem linha (sondagens) sao ignoradas.
# Argumentos: porta resposta limite_s (0 = sem limite). Saida 3 = timeout.
PY_CTL='
import socket, sys
porta, resposta, limite = int(sys.argv[1]), sys.argv[2], float(sys.argv[3])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.bind(("0.0.0.0", porta))
except OSError as e:
    print("bind:", e, file=sys.stderr)
    sys.exit(4)
srv.listen(4)
if limite > 0:
    srv.settimeout(limite)
while True:
    try:
        con, end = srv.accept()
    except socket.timeout:
        sys.exit(3)
    con.settimeout(30)
    buf = b""
    try:
        while b"\n" not in buf and len(buf) < 4096:
            d = con.recv(4096)
            if not d:
                break
            buf += d
    except OSError:
        pass
    if b"\n" not in buf:
        con.close()
        continue
    linha = buf.split(b"\n", 1)[0].decode("utf-8", "replace").strip()
    try:
        con.sendall((resposta + "\n").encode())
        con.shutdown(socket.SHUT_WR)
        while con.recv(4096):
            pass
    except OSError:
        pass
    con.close()
    break
srv.close()
print(end[0], linha, flush=True)
'

escutar_ctl() {
    python3 -c "$PY_CTL" "$PORTA_CTL" "$1" "$2"
}

# Envia uma linha a porta de controle e imprime a resposta, repetindo o
# connect (o outro lado pode ainda nao estar escutando) por ate $2 s.
ctl_pedido() {
    local linha=$1 limite=$2 resp rc
    local fim=$((SECONDS + limite))

    while :; do
        resp=$(timeout 40 bash -c '
            exec 3<>"/dev/tcp/$1/$2" || exit 9
            printf "%s\n" "$3" >&3
            IFS= read -r -t 30 r <&3 || exit 8
            printf "%s\n" "$r"' _ "$IP" "$PORTA_CTL" "$linha" 2>/dev/null)
        rc=$?
        if [ $rc -eq 0 ]; then
            printf '%s\n' "$resp"
            return 0
        fi
        [ $SECONDS -lt $fim ] || return 1
        sleep 0.5
    done
}

# ---------------------------------------------------------------------------
# Uma execucao (modos local e clientes). Define RES_COD, RES_LINHA,
# RES_RETR (retrans deste lado) e RES_RETR_SRV (do servidor, modo rede).
# ---------------------------------------------------------------------------

executar_local() {
    local n=$1 rep=$2 tent=$3
    local pre r0 r1
    pre=$(prefixo_log "$n" "$rep" "$tent")

    r0=$(retrans_atual)
    if ! iniciar_servidor "$n" "$W" "$D" "$AMBIENTE" "$pre"; then
        RES_COD=1; RES_LINHA=""; RES_RETR=0; RES_RETR_SRV=""; CLI_ERROS=$n
        return
    fi
    lancar_clientes "$IP" "$PORTA" "$n" "$rep" "$tent" "$pre"
    esperar_servidor "$pre" $((ESPERA_FIM_S + 5))
    r1=$(retrans_atual)

    RES_COD=$SRV_COD
    RES_LINHA=$SRV_LINHA
    RES_RETR=$((r1 - r0))
    RES_RETR_SRV=""
}

executar_rede() {
    local n=$1 rep=$2 tent=$3
    local pre r0 r1 resp limite=60
    pre=$(prefixo_log "$n" "$rep" "$tent")

    # Na primeira execucao o lado servidor pode ainda nao ter sido iniciado.
    [ "$PRIMEIRA" -eq 1 ] && limite=$T_ESPERA_SERVIDOR

    resp=$(ctl_pedido "RUN $n $rep $tent $W $D $AMBIENTE" "$limite")
    if [ "$resp" != ACK ]; then
        msg "ERRO: sem resposta do servidor $IP:$PORTA_CTL ao RUN ('$resp')."
        exit 1
    fi
    PRIMEIRA=0

    r0=$(retrans_atual)
    lancar_clientes "$IP" "$PORTA" "$n" "$rep" "$tent" "$pre"
    r1=$(retrans_atual)

    resp=$(ctl_pedido "RES $n $rep $tent" "$T_RES")
    local tag rn rr rt cod rsrv linha
    read -r tag rn rr rt cod rsrv linha <<<"$resp"
    if [ "$tag" != RES ] || [ "$rn" != "$n" ] || [ "$rr" != "$rep" ] ||
       [ "$rt" != "$tent" ]; then
        msg "ERRO: resposta fora de sequencia do servidor: '$resp'."
        msg "Os dois lados perderam a sincronia; reinicie ambos."
        exit 1
    fi
    [ "$linha" = "-" ] && linha=""

    echo "$resp" >"${pre}_servidor_res.txt"
    RES_COD=$cod
    RES_LINHA=$linha
    RES_RETR=$((r1 - r0))
    RES_RETR_SRV=$rsrv
}

# ---------------------------------------------------------------------------
# Laco principal dos modos local e clientes (mestre da sequencia)
# ---------------------------------------------------------------------------

modo_mestre() {
    local plano=() item n rep tent cod t_ini
    local total feitas=0 t0=$SECONDS

    [ "$AQUEC" -eq 1 ] && plano+=("$N_MAX:0")
    for ((rep = 1; rep <= REPS; rep++)); do
        for ((n = N_MIN; n <= N_MAX; n++)); do
            plano+=("$n:$rep")
        done
    done
    total=${#plano[@]}

    msg "Rodada em $RODADA"
    msg "Modo $MODO, ambiente $AMBIENTE, servidor $IP:$PORTA," \
        "N=$N_MIN..$N_MAX, $REPS rep., W=$W D=$D M=$MARGEM, bloco $BLOCO B."
    msg "Execucoes previstas: $total (estimativa ~$(fmt_tempo $((total * (W + D + MARGEM + PAUSA + 1)))), sem retentativas)."

    for item in "${plano[@]}"; do
        n=${item%%:*}
        rep=${item##*:}
        feitas=$((feitas + 1))

        for ((tent = 1; tent <= MAX_TENT; tent++)); do
            t_ini=$(date -Iseconds)
            if [ "$rep" -eq 0 ]; then
                printf '[%3d/%d] aquecimento N=%2d ... ' "$feitas" "$total" "$n"
            else
                printf '[%3d/%d] rep %2d/%d N=%2d tent %d ... ' \
                    "$feitas" "$total" "$rep" "$REPS" "$n" "$tent"
            fi

            if [ "$MODO" = local ]; then
                executar_local "$n" "$rep" "$tent"
            else
                executar_rede "$n" "$rep" "$tent"
            fi
            cod=$RES_COD

            gravar_csv "$RES_LINHA" "$rep" "$tent" "$RES_RETR" "$RES_RETR_SRV"

            local sit mbps
            sit=$(situacao_de "$cod")
            [ "$rep" -eq 0 ] && sit="aquecimento($sit)"
            mbps=$(mbps_de "$RES_LINHA")
            echo "$t_ini,$n,$rep,$tent,$cod,$CLI_ERROS,$mbps,$RES_RETR,$sit" >>"$TENT_CSV"

            local dec=$((SECONDS - t0))
            local resto=$(( dec * (total - feitas) / feitas ))
            local txt="$mbps Mbps $sit | retrans $RES_RETR"
            [ -n "$RES_RETR_SRV" ] && txt+=" (srv $RES_RETR_SRV)"
            [ "$CLI_ERROS" -gt 0 ] && txt+=" | $CLI_ERROS cliente(s) com erro"
            txt+=" | $(fmt_tempo $dec) decorridos, ~$(fmt_tempo $resto) restantes"
            echo "$txt"
            echo "[$feitas/$total] N=$n rep=$rep tent=$tent: $txt" >>"$PROGRESSO"

            # O aquecimento e descartado de qualquer jeito: nao se repete.
            if [ "$cod" -eq 0 ] || [ "$rep" -eq 0 ]; then
                break
            fi
            if [ "$tent" -eq "$MAX_TENT" ]; then
                msg "AVISO: N=$n rep=$rep sem execucao valida apos $MAX_TENT tentativas."
            fi
            sleep "$PAUSA"
        done

        [ "$feitas" -lt "$total" ] && sleep "$PAUSA"
    done

    if [ "$MODO" = clientes ]; then
        ctl_pedido "FIM" 30 >/dev/null || msg "AVISO: servidor nao confirmou FIM."
    fi

    local validas
    validas=$(awk -F, 'NR > 1 && $3 > 0 && $8 == 1' "$CSV" | wc -l)
    msg "Fim: $validas execucoes validas (sem o aquecimento) em $(fmt_tempo $((SECONDS - t0)))."
    msg "CSV: $CSV"
}

# ---------------------------------------------------------------------------
# Laco do modo servidor (escravo: faz o que o lado clientes pedir)
# ---------------------------------------------------------------------------

modo_servidor() {
    local req peer cmd n rep tent w d amb pre r0 r1 retr resp ja_rota=0
    local cont=0

    esperar_porta_livre "$PORTA" 5 || erro "porta $PORTA ocupada."
    esperar_porta_livre "$PORTA_CTL" 5 || erro "porta $PORTA_CTL ocupada."

    msg "Rodada em $RODADA"
    msg "Modo servidor: dados na porta $PORTA, controle na porta $PORTA_CTL."
    msg "Aguardando o lado clientes (run_experimento.sh clientes <este_ip>)..."

    while :; do
        req=$(escutar_ctl ACK 0) || erro "falha no escutador da porta de controle."
        read -r peer cmd n rep tent w d amb <<<"$req"

        if [ "$ja_rota" -eq 0 ]; then
            anexar_rota "$peer"
            ja_rota=1
        fi

        if [ "$cmd" = FIM ]; then
            msg "FIM recebido de $peer."
            break
        fi

        if [ "$cmd" != RUN ] || ! eh_inteiro "${n:-x}" || ! eh_inteiro "${rep:-x}" ||
           ! eh_inteiro "${tent:-x}" || ! eh_inteiro "${w:-x}" ||
           ! eh_inteiro "${d:-x}" || [[ ! ${amb:-} =~ ^[A-Za-z0-9_.-]+$ ]]; then
            msg "Pedido ignorado de $peer: '$req'"
            continue
        fi

        cont=$((cont + 1))
        pre=$(prefixo_log "$n" "$rep" "$tent")
        printf '[%3d] de %s: N=%2d rep %2d tent %d (W=%d D=%d) ... ' \
            "$cont" "$peer" "$n" "$rep" "$tent" "$w" "$d"

        r0=$(retrans_atual)
        if iniciar_servidor "$n" "$w" "$d" "$amb" "$pre"; then
            esperar_servidor "$pre"
        else
            SRV_COD=1
            SRV_LINHA=""
        fi
        r1=$(retrans_atual)
        retr=$((r1 - r0))

        gravar_csv "$SRV_LINHA" "$rep" "$tent" "$retr" "$retr"
        echo "$(date -Iseconds),$n,$rep,$tent,$SRV_COD,,$(mbps_de "$SRV_LINHA"),$retr,$(situacao_de "$SRV_COD")" >>"$TENT_CSV"
        echo "$(mbps_de "$SRV_LINHA") Mbps $(situacao_de "$SRV_COD") | retrans $retr"
        echo "[$cont] N=$n rep=$rep tent=$tent: $(mbps_de "$SRV_LINHA") Mbps $(situacao_de "$SRV_COD") retrans $retr" >>"$PROGRESSO"

        resp="RES $n $rep $tent $SRV_COD $retr ${SRV_LINHA:--}"
        req=$(escutar_ctl "$resp" "$T_RES")
        case $? in
        0)
            # O pedido deve ser "RES N rep tent" desta mesma execucao.
            if [ "${req#* }" != "RES $n $rep $tent" ]; then
                msg "AVISO: esperava 'RES $n $rep $tent' e recebi '$req'."
            fi
            ;;
        3) msg "AVISO: o lado clientes nao pediu o resultado em $T_RES s." ;;
        *) erro "falha no escutador da porta de controle." ;;
        esac
    done

    msg "Modo servidor encerrado; CSV: $CSV"
}

# ---------------------------------------------------------------------------

coletar_ambiente "$RODADA/ambiente.txt" "$IP"
salvar_parametros
PRIMEIRA=1

if [ "$MODO" = servidor ]; then
    modo_servidor
else
    modo_mestre
fi
