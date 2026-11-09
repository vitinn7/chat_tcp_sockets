/*
 * chat_server.c - servidor do chat modificado para medir throughput.
 * Espera N clientes, manda "GO" para todos e conta os bytes recebidos
 * por cada thread. Uma thread de medicao calcula:
 *     Mbps = (S1 - S0) * 8 / (dt * 1e6)
 * O resultado sai numa linha CSV.
 * Uso: chat_server [-H] [-s] <porta> <N> [warmup_s=2] [janela_s=10] [rotulo]
 *   -H  imprime o cabecalho do CSV
 *   -s  imprime no stderr a taxa de cada segundo
 * Saida: 0 = valida, 2 = invalida, 1 = erro.
 */

#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdatomic.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define TAM_BUFFER 1024
#define MAX_CLIENTES 100
#define TAM_RECV 65536
#define ESPERA_FIM_S 5
#define NS_POR_S 1000000000LL

typedef struct Cliente {
    int fd;
    int indice;
    char nome[32];
    struct Cliente *prox;
} Cliente;

/* Um contador por cliente, cada um na sua linha de cache (64 B) */
typedef struct {
    _Alignas(64) _Atomic uint64_t bytes;
    _Atomic int64_t fim_ns;  /* quando a conexao terminou; 0 = ativa */
} Contador;

static Contador contadores[MAX_CLIENTES];

Cliente *clientes = NULL;
int num_clientes = 0;

pthread_mutex_t mutex_clientes = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t cond_estado;
int go_enviado = 0;
int registro_falhou = 0;
int num_encerrados = 0;

static int n_esperados;
static int aquecimento_s = 2;
static int janela_s = 10;
static int mostrar_amostras = 0;

static int64_t t_go_ns;
static int64_t t0_ns, t1_ns;
static uint64_t s0_cliente[MAX_CLIENTES], s1_cliente[MAX_CLIENTES];

/* Relogio monotonico em nanossegundos */
static int64_t agora_ns(void) {
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * NS_POR_S + ts.tv_nsec;
}

/* Dorme ate um instante absoluto, sem acumular atraso */
static void dormir_ate(int64_t alvo_ns) {
    struct timespec ts;
    int r;

    ts.tv_sec = alvo_ns / NS_POR_S;
    ts.tv_nsec = alvo_ns % NS_POR_S;

    do {
        r = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL);
    } while (r == EINTR);
}

/* Soma os contadores de todos os clientes */
static uint64_t somar_contadores(uint64_t *por_cliente) {
    uint64_t total = 0;

    for (int i = 0; i < n_esperados; i++) {
        uint64_t b = atomic_load_explicit(&contadores[i].bytes,
                                          memory_order_relaxed);
        if (por_cliente != NULL)
            por_cliente[i] = b;
        total += b;
    }

    return total;
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

/* Le uma linha terminada em '\n' */
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

/* Manda a mensagem para todos menos o remetente (aqui so o "GO") */
void enviar_para_todos(const char *mensagem, Cliente *remetente) {
    pthread_mutex_lock(&mutex_clientes);

    Cliente *atual = clientes;

    while (atual != NULL) {
        if (atual != remetente) {
            if (enviar_tudo(atual->fd, mensagem,
                            strlen(mensagem)) == -1) {
                fprintf(stderr,
                        "Falha ao enviar para %s.\n",
                        atual->nome);
            }
        }

        atual = atual->prox;
    }

    pthread_mutex_unlock(&mutex_clientes);
}

/* Tira o cliente da lista, fecha o socket e avisa o main */
static void encerrar_cliente(Cliente *cliente, int registrado) {
    pthread_mutex_lock(&mutex_clientes);

    if (registrado) {
        Cliente **atual = &clientes;

        while (*atual != NULL && *atual != cliente)
            atual = &(*atual)->prox;

        if (*atual == cliente) {
            *atual = cliente->prox;
            num_clientes--;
        }
    }

    close(cliente->fd);
    cliente->fd = -1;
    num_encerrados++;
    pthread_cond_broadcast(&cond_estado);

    pthread_mutex_unlock(&mutex_clientes);
}

void *atender_cliente(void *arg) {
    Cliente *cliente = arg;
    char buffer[TAM_BUFFER];
    Contador *contador = &contadores[cliente->indice];
    int ultimo = 0;

    /* A primeira linha e o nome */
    ssize_t n = ler_linha(cliente->fd, buffer, sizeof(buffer));

    if (n <= 0 || buffer[0] == '\0') {
        fprintf(stderr, "Cliente %d nao enviou um nome valido.\n",
                cliente->indice + 1);
        atomic_store(&contador->fim_ns, agora_ns());

        pthread_mutex_lock(&mutex_clientes);
        registro_falhou = 1;
        pthread_mutex_unlock(&mutex_clientes);

        encerrar_cliente(cliente, 0);
        return NULL;
    }

    snprintf(cliente->nome, sizeof(cliente->nome), "%.*s",
             (int)sizeof(cliente->nome) - 1, buffer);

    pthread_mutex_lock(&mutex_clientes);

    cliente->prox = clientes;
    clientes = cliente;
    num_clientes++;

    if (num_clientes == n_esperados)
        ultimo = 1;

    pthread_mutex_unlock(&mutex_clientes);

    fprintf(stderr, "Usuario conectado: %s\n", cliente->nome);

    /* O ultimo a chegar libera todos com o "GO" */
    if (ultimo) {
        enviar_para_todos("GO\n", NULL);

        pthread_mutex_lock(&mutex_clientes);
        t_go_ns = agora_ns();
        go_enviado = 1;
        pthread_cond_broadcast(&cond_estado);
        pthread_mutex_unlock(&mutex_clientes);

        fprintf(stderr, "GO enviado a %d cliente(s).\n", n_esperados);
    }

    char *dados = malloc(TAM_RECV);

    if (dados == NULL) {
        perror("malloc");
        atomic_store(&contador->fim_ns, agora_ns());
        encerrar_cliente(cliente, 1);
        return NULL;
    }

    /* Recebe, descarta e soma os bytes no contador desta thread */
    while (1) {
        n = recv(cliente->fd, dados, TAM_RECV, 0);

        if (n > 0) {
            atomic_fetch_add_explicit(&contador->bytes, (uint64_t)n,
                                      memory_order_relaxed);
            continue;
        }

        if (n == -1 && errno == EINTR)
            continue;

        break;  /* 0: o cliente fechou */
    }

    atomic_store(&contador->fim_ns, agora_ns());

    if (n == -1)
        perror("recv");

    free(dados);

    fprintf(stderr, "Usuario desconectado: %s\n", cliente->nome);

    encerrar_cliente(cliente, 1);
    return NULL;
}

/* Le S0 em t0 (fim do aquecimento) e S1 em t1 (fim da janela) */
void *medir(void *arg) {
    (void)arg;

    int64_t alvo0 = t_go_ns + (int64_t)aquecimento_s * NS_POR_S;

    dormir_ate(alvo0);
    t0_ns = agora_ns();
    somar_contadores(s0_cliente);

    uint64_t soma_anterior = 0;
    int64_t t_anterior = t0_ns;

    for (int i = 0; i < n_esperados; i++)
        soma_anterior += s0_cliente[i];

    for (int seg = 1; seg <= janela_s; seg++) {
        dormir_ate(alvo0 + (int64_t)seg * NS_POR_S);

        int64_t t = agora_ns();
        uint64_t soma = somar_contadores(seg == janela_s ? s1_cliente : NULL);

        if (seg == janela_s)
            t1_ns = t;

        if (mostrar_amostras) {
            double dt = (double)(t - t_anterior) / 1e9;
            fprintf(stderr, "amostra,%d,%.6f,%.3f\n", seg, dt,
                    (double)(soma - soma_anterior) * 8.0 / (dt * 1e6));
        }

        soma_anterior = soma;
        t_anterior = t;
    }

    return NULL;
}

/* Converte texto em inteiro dentro de uma faixa */
static int ler_inteiro(const char *texto, int minimo, int maximo,
                       int *saida) {
    char *fim;

    errno = 0;
    long valor = strtol(texto, &fim, 10);

    if (errno != 0 || fim == texto || *fim != '\0' ||
        valor < minimo || valor > maximo)
        return -1;

    *saida = (int)valor;
    return 0;
}

static void uso(const char *programa) {
    fprintf(stderr,
            "Uso: %s [-H] [-s] <porta> <N> [warmup_s=2] "
            "[janela_s=10] [rotulo]\n"
            "  -H  imprime o cabecalho do CSV\n"
            "  -s  imprime amostras por segundo no stderr\n",
            programa);
}

/* Derruba as conexoes que ainda estao abertas */
static void forcar_encerramento(Cliente **todos, int n) {
    pthread_mutex_lock(&mutex_clientes);

    for (int i = 0; i < n; i++) {
        if (todos[i]->fd != -1)
            shutdown(todos[i]->fd, SHUT_RDWR);
    }

    pthread_mutex_unlock(&mutex_clientes);
}

static void esperar_threads(pthread_t *threads, Cliente **todos, int n) {
    for (int i = 0; i < n; i++) {
        pthread_join(threads[i], NULL);
        free(todos[i]);
    }
}

int main(int argc, char *argv[]) {
    int sock_servidor;
    struct sockaddr_in endereco_servidor;
    const char *rotulo = "teste";
    int imprimir_cabecalho = 0;
    int porta;
    int opcao;

    while ((opcao = getopt(argc, argv, "Hs")) != -1) {
        switch (opcao) {
        case 'H':
            imprimir_cabecalho = 1;
            break;
        case 's':
            mostrar_amostras = 1;
            break;
        default:
            uso(argv[0]);
            return EXIT_FAILURE;
        }
    }

    int nargs = argc - optind;

    if (nargs < 2 || nargs > 5 ||
        ler_inteiro(argv[optind], 1, 65535, &porta) == -1 ||
        ler_inteiro(argv[optind + 1], 1, MAX_CLIENTES,
                    &n_esperados) == -1 ||
        (nargs >= 3 &&
         ler_inteiro(argv[optind + 2], 0, 3600, &aquecimento_s) == -1) ||
        (nargs >= 4 &&
         ler_inteiro(argv[optind + 3], 1, 3600, &janela_s) == -1)) {
        uso(argv[0]);
        return EXIT_FAILURE;
    }

    if (nargs >= 5)
        rotulo = argv[optind + 4];

    signal(SIGPIPE, SIG_IGN);

    /* A espera com timeout tambem usa o relogio monotonico */
    pthread_condattr_t atributos;

    if (pthread_condattr_init(&atributos) != 0 ||
        pthread_condattr_setclock(&atributos, CLOCK_MONOTONIC) != 0 ||
        pthread_cond_init(&cond_estado, &atributos) != 0) {
        fprintf(stderr, "Erro ao criar variavel de condicao.\n");
        return EXIT_FAILURE;
    }

    pthread_condattr_destroy(&atributos);

    sock_servidor = socket(AF_INET, SOCK_STREAM, 0);

    if (sock_servidor == -1) {
        perror("socket");
        return EXIT_FAILURE;
    }

    int reusar = 1;

    if (setsockopt(sock_servidor, SOL_SOCKET, SO_REUSEADDR,
                   &reusar, sizeof(reusar)) == -1)
        perror("setsockopt");

    memset(&endereco_servidor, 0, sizeof(endereco_servidor));
    endereco_servidor.sin_family = AF_INET;
    endereco_servidor.sin_addr.s_addr = htonl(INADDR_ANY);
    endereco_servidor.sin_port = htons(porta);

    if (bind(sock_servidor, (struct sockaddr *)&endereco_servidor,
             sizeof(endereco_servidor)) == -1) {
        perror("bind");
        close(sock_servidor);
        return EXIT_FAILURE;
    }

    /* Fila grande: os N clientes conectam quase juntos */
    if (listen(sock_servidor, SOMAXCONN) == -1) {
        perror("listen");
        close(sock_servidor);
        return EXIT_FAILURE;
    }

    fprintf(stderr, "Servidor de medicao na porta %d, esperando %d "
            "cliente(s) (aquecimento %d s, janela %d s).\n",
            porta, n_esperados, aquecimento_s, janela_s);

    /* Aceita exatamente N conexoes */
    Cliente *todos[MAX_CLIENTES];
    pthread_t threads[MAX_CLIENTES];
    int aceitos = 0;

    while (aceitos < n_esperados) {
        struct sockaddr_in endereco_cliente;
        socklen_t tam_endereco = sizeof(endereco_cliente);

        int sock_cliente = accept(
            sock_servidor,
            (struct sockaddr *)&endereco_cliente,
            &tam_endereco
        );

        if (sock_cliente == -1) {
            if (errno == EINTR)
                continue;

            perror("accept");
            continue;
        }

        Cliente *cliente = malloc(sizeof(Cliente));

        if (cliente == NULL) {
            perror("malloc");
            close(sock_cliente);
            continue;
        }

        cliente->fd = sock_cliente;
        cliente->indice = aceitos;
        cliente->nome[0] = '\0';
        cliente->prox = NULL;

        if (pthread_create(&threads[aceitos], NULL,
                           atender_cliente, cliente) != 0) {
            fprintf(stderr, "Erro ao criar thread.\n");
            close(sock_cliente);
            free(cliente);
            exit(EXIT_FAILURE);
        }

        todos[aceitos++] = cliente;
    }

    close(sock_servidor);

    /* Espera o GO ou uma falha no registro */
    pthread_mutex_lock(&mutex_clientes);

    while (!go_enviado && !registro_falhou)
        pthread_cond_wait(&cond_estado, &mutex_clientes);

    int falhou = registro_falhou;

    pthread_mutex_unlock(&mutex_clientes);

    if (falhou) {
        fprintf(stderr, "Registro falhou; execucao abortada.\n");
        forcar_encerramento(todos, aceitos);
        esperar_threads(threads, todos, aceitos);
        return EXIT_FAILURE;
    }

    pthread_t medidor;

    if (pthread_create(&medidor, NULL, medir, NULL) != 0) {
        fprintf(stderr, "Erro ao criar thread de medicao.\n");
        forcar_encerramento(todos, aceitos);
        esperar_threads(threads, todos, aceitos);
        return EXIT_FAILURE;
    }

    pthread_join(medidor, NULL);

    /* Da ate ESPERA_FIM_S para os clientes fecharem */
    struct timespec limite;
    int64_t limite_ns = agora_ns() + (int64_t)ESPERA_FIM_S * NS_POR_S;

    limite.tv_sec = limite_ns / NS_POR_S;
    limite.tv_nsec = limite_ns % NS_POR_S;

    pthread_mutex_lock(&mutex_clientes);

    while (num_encerrados < aceitos) {
        if (pthread_cond_timedwait(&cond_estado, &mutex_clientes,
                                   &limite) == ETIMEDOUT)
            break;
    }

    int restantes = aceitos - num_encerrados;

    pthread_mutex_unlock(&mutex_clientes);

    if (restantes > 0) {
        fprintf(stderr, "%d cliente(s) nao fecharam em %d s; "
                "encerrando a forca.\n", restantes, ESPERA_FIM_S);
        forcar_encerramento(todos, aceitos);
    }

    esperar_threads(threads, todos, aceitos);

    /* Invalida se algum cliente saiu antes de t1 ou nao mandou nada */
    int valido = 1;

    for (int i = 0; i < n_esperados; i++) {
        int64_t fim = atomic_load(&contadores[i].fim_ns);

        if (fim != 0 && fim < t1_ns) {
            fprintf(stderr, "Cliente %d encerrou %.3f s antes de t1: "
                    "execucao invalida.\n", i + 1,
                    (double)(t1_ns - fim) / 1e9);
            valido = 0;
        }

        if (s1_cliente[i] == s0_cliente[i]) {
            fprintf(stderr, "Cliente %d nao entregou bytes na janela: "
                    "execucao invalida.\n", i + 1);
            valido = 0;
        }
    }

    /* Taxa agregada: bytes de todas as threads na janela / dt real */
    uint64_t total = 0;

    for (int i = 0; i < n_esperados; i++)
        total += s1_cliente[i] - s0_cliente[i];

    double dt_s = (double)(t1_ns - t0_ns) / 1e9;
    double mbps = (double)total * 8.0 / (dt_s * 1e6);

    if (imprimir_cabecalho)
        printf("rotulo,N,bytes,dt_s,mbps,valido,bytes_por_cliente\n");

    printf("%s,%d,%llu,%.6f,%.3f,%d,", rotulo, n_esperados,
           (unsigned long long)total, dt_s, mbps, valido);

    for (int i = 0; i < n_esperados; i++)
        printf("%s%llu", i == 0 ? "" : ";",
               (unsigned long long)(s1_cliente[i] - s0_cliente[i]));

    printf("\n");
    fflush(stdout);

    pthread_cond_destroy(&cond_estado);
    pthread_mutex_destroy(&mutex_clientes);

    return valido ? EXIT_SUCCESS : 2;
}
