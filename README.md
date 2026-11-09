# Chat TCP modificado para medir throughput

Trabalho 1 de Redes de Computadores. Partimos do chat TCP com uma *thread* por cliente e o modificamos para medir a **taxa de transmissão agregada (Mbps)** que o servidor recebe de 1 a 10 clientes simultâneos.

- `chat_server.c`: espera N clientes, manda `GO` para todos começarem juntos, conta os bytes recebidos por cada *thread* e calcula a taxa.
- `chat_client.c`: conecta, envia o nome, espera o `GO` e envia blocos de dados sem parar durante um tempo definido, sem digitação.

## Requisitos

Linux com `gcc` (C11), `pthread` e `make`. Foi testado no Ubuntu 24.04 e no 26.04, ambos no WSL2.

## Compilação

```bash
make          # gera ./chat_server e ./chat_client
make clean    # apaga os binários
```

## Execução

```bash
./chat_server [-H] [-s] <porta> <N> [aquecimento_s=2] [janela_s=10] [rotulo]
./chat_client <ip_servidor> <porta> [duracao_s=13] [bloco_bytes=65536] [nome]
```

| Opção | Significado |
|---|---|
| `N` | quantos clientes o servidor espera antes de mandar o `GO` |
| `aquecimento_s` | segundos descartados depois do `GO` |
| `janela_s` | segundos medidos |
| `-H` | imprime o cabeçalho do CSV |
| `-s` | imprime no stderr a taxa de cada segundo |
| `duracao_s` | quanto tempo o cliente transmite (aquecimento + janela + 1 s de margem) |
| `bloco_bytes` | tamanho de cada `send` |

### No mesmo computador (3 clientes)

```bash
./chat_server -H 5000 3 &
for i in 1 2 3; do ./chat_client 127.0.0.1 5000 13 65536 c$i & done
wait
```

No WSL2 em modo de rede espelhado, use `127.0.0.2` no lugar de `127.0.0.1`. Nesse modo, o `127.0.0.1` passa pelo Windows e trava com 3 ou mais clientes.

### Em dois computadores

No PC servidor:
```bash
./chat_server -H 5000 3
```
No PC dos clientes (troque pelo IP do servidor):
```bash
for i in 1 2 3; do ./chat_client 192.168.0.14 5000 13 65536 c$i & done
wait
```
A porta 5000 precisa estar liberada no firewall do PC servidor.

## Saída

O servidor imprime uma linha CSV:

```
rotulo,N,bytes,dt_s,mbps,valido,bytes_por_cliente
teste,3,28030205899,3.000005,74747.103,1,9377873867;9300541440;9351790592
```

Código de saída: `0` = medição válida, `2` = inválida (um cliente parou antes do fim ou não mandou nada na janela), `1` = erro.

Cada cliente imprime no stderr: `cliente,<nome>,<bytes_enviados>,<segundos>`.

## Como a taxa é calculada

Cada *thread* do servidor soma os bytes recebidos num contador próprio (atômico, sem mutex). Uma *thread* de medição lê a soma de todos os contadores em dois instantes:

- **S0** em t0, ao fim do aquecimento (2 s depois do `GO`);
- **S1** em t1, ao fim da janela (10 s depois de t0).

```
Mbps = (S1 - S0) * 8 / ((t1 - t0) * 1 000 000)
```

O `* 8` converte bytes em bits. O tempo vem do `CLOCK_MONOTONIC`, um relógio que não muda com ajustes de hora.

## O que mudou em relação ao chat original

| Original | Modificado |
|---|---|
| `recv` de 1 byte por vez | `recv` de até 64 KiB, dados descartados |
| repassa cada mensagem a todos (broadcast com mutex) | broadcast desligado |
| cliente lê do teclado (`fgets`) | cliente envia o mesmo bloco de 64 KiB em laço até o prazo |
| sem contagem nem relógio | contador atômico por *thread* + *thread* de medição |
| cada cliente começa quando conecta | barreira: todos começam com o `GO` |
| `listen` com fila 10, aceita para sempre | `listen(SOMAXCONN)`, aceita exatamente N |
| sai com `/quit` | `shutdown(SHUT_WR)` e espera o servidor fechar |
