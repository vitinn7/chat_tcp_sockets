/*
 * chat_client.c - cliente do chat modificado para medir throughput.
 *
 * Conecta, manda o nome, espera o "GO" do servidor e envia o mesmo
 * bloco em laco ate acabar o tempo. No fim imprime os bytes enviados.
 *
 * Uso: chat_client <ip> <porta> [duracao_s=13] [bloco_bytes=65536] [nome]
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include <netinet/in.h>

#define TAM_BUFFER 1024
#define TEMPO_LIMITE_S 10
#define NS_POR_S 1000000000LL

int sock;

/* Relogio monotonico em nanossegundos */
static int64_t agora_ns(void) {
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * NS_POR_S + ts.tv_nsec;
}

/* Envia tudo, mesmo se o send mandar so uma parte */
int enviar_tudo(int fd, const char *dados, size_t tamanho) {
    size_t enviado = 0;

    while (enviado < tamanho) {
        ssize_t n = send(fd, dados + enviado, tamanho - enviado,
                         MSG_NOSIGNAL);

        if (n == -1) {
            if (errno == EINTR)
                continue;
            return -1;
        }

        if (n == 0)
            return -1;

        enviado += (size_t)n;
    }

    return 0;
}

/* Le uma linha terminada em '\n' (usada so para o "GO") */
ssize_t ler_linha(int fd, char *buffer, size_t capacidade) {
    size_t pos = 0;

    while (pos < capacidade - 1) {
        char c;
        ssize_t n = recv(fd, &c, 1, 0);

        if (n == 0)
            return pos == 0 ? 0 : (ssize_t)pos;

        if (n == -1) {
            if (errno == EINTR)
                continue;
            return -1;
        }

        if (c == '\n')
            break;

        if (c != '\r')
            buffer[pos++] = c;
    }

    buffer[pos] = '\0';
    return (ssize_t)pos;
}

/* Converte texto em inteiro dentro de uma faixa */
static int ler_inteiro(const char *texto, long minimo, long maximo,
                       long *saida) {
    char *fim;

    errno = 0;
    long valor = strtol(texto, &fim, 10);

    if (errno != 0 || fim == texto || *fim != '\0' ||
        valor < minimo || valor > maximo)
        return -1;

    *saida = valor;
    return 0;
}

int main(int argc, char *argv[]) {
    struct sockaddr_in endereco_servidor;
    char nome[32];
    char buffer[TAM_BUFFER];
    long porta;
    long duracao_s = 13;
    long tam_bloco = 65536;

    if (argc < 3 || argc > 6 ||
        ler_inteiro(argv[2], 1, 65535, &porta) == -1 ||
        (argc >= 4 && ler_inteiro(argv[3], 1, 3600, &duracao_s) == -1) ||
        (argc >= 5 && ler_inteiro(argv[4], 1, 64L * 1024 * 1024,
                                  &tam_bloco) == -1)) {
        fprintf(stderr, "Uso: %s <IP> <porta> [duracao_s=13] "
                "[bloco_bytes=65536] [nome]\n", argv[0]);
        return EXIT_FAILURE;
    }

    /* Sem nome, usa "cli<pid>" */
    if (argc >= 6)
        snprintf(nome, sizeof(nome), "%s", argv[5]);
    else
        snprintf(nome, sizeof(nome), "cli%ld", (long)getpid());

    if (nome[0] == '\0' || strpbrk(nome, "\r\n") != NULL) {
        fprintf(stderr, "Nome invalido.\n");
        return EXIT_FAILURE;
    }

    signal(SIGPIPE, SIG_IGN);

    sock = socket(AF_INET, SOCK_STREAM, 0);

    if (sock == -1) {
        perror("socket");
        return EXIT_FAILURE;
    }

    memset(&endereco_servidor, 0, sizeof(endereco_servidor));
    endereco_servidor.sin_family = AF_INET;
    endereco_servidor.sin_port = htons((uint16_t)porta);

    if (inet_pton(AF_INET, argv[1],
                  &endereco_servidor.sin_addr) != 1) {
        fprintf(stderr, "Endereco IPv4 invalido.\n");
        close(sock);
        return EXIT_FAILURE;
    }

    if (connect(sock, (struct sockaddr *)&endereco_servidor,
                sizeof(endereco_servidor)) == -1) {
        perror("connect");
        close(sock);
        return EXIT_FAILURE;
    }

    /* Primeira linha e o nome, igual ao chat original */
    if (enviar_tudo(sock, nome, strlen(nome)) == -1 ||
        enviar_tudo(sock, "\n", 1) == -1) {
        perror("send");
        close(sock);
        return EXIT_FAILURE;
    }

    /* Espera o "GO" para comecar */
    ssize_t n = ler_linha(sock, buffer, sizeof(buffer));

    if (n <= 0 || strcmp(buffer, "GO") != 0) {
        if (n == -1)
            perror("recv");
        fprintf(stderr, "%s: nao recebeu GO do servidor.\n", nome);
        close(sock);
        return EXIT_FAILURE;
    }

    /* O conteudo do bloco nao importa */
    char *bloco = malloc((size_t)tam_bloco);

    if (bloco == NULL) {
        perror("malloc");
        close(sock);
        return EXIT_FAILURE;
    }

    memset(bloco, 'x', (size_t)tam_bloco);

    /* Evita ficar preso num send se o servidor parar de ler */
    struct timeval limite = { TEMPO_LIMITE_S, 0 };

    if (setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO,
                   &limite, sizeof(limite)) == -1)
        perror("setsockopt");

    /* Envia o bloco em laco ate o prazo, sem printf aqui dentro */
    uint64_t total_enviado = 0;
    int erro_envio = 0;
    int64_t inicio = agora_ns();
    int64_t prazo = inicio + duracao_s * NS_POR_S;

    while (agora_ns() < prazo) {
        if (enviar_tudo(sock, bloco, (size_t)tam_bloco) == -1) {
            erro_envio = errno;
            break;
        }

        total_enviado += (uint64_t)tam_bloco;
    }

    double duracao_real = (double)(agora_ns() - inicio) / 1e9;

    free(bloco);

    if (erro_envio != 0)
        fprintf(stderr, "%s: send: %s\n", nome, strerror(erro_envio));

    /* Manda o FIN e espera o servidor fechar */
    if (shutdown(sock, SHUT_WR) == -1)
        perror("shutdown");

    if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
                   &limite, sizeof(limite)) == -1)
        perror("setsockopt");

    while ((n = recv(sock, buffer, sizeof(buffer), 0)) != 0) {
        if (n == -1) {
            if (errno == EINTR)
                continue;
            perror("recv");
            break;
        }
    }

    close(sock);

    fprintf(stderr, "cliente,%s,%llu,%.6f\n", nome,
            (unsigned long long)total_enviado, duracao_real);

    return erro_envio == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
