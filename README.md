# xhttp-cloudlab

Perfil do CloudLab para os experimentos do xHTTP: um **servidor** e um **cliente**
ligados por um link dedicado de **100 Gbit/s**, os dois no mesmo switch.

| Nó | Tipo padrão | Por quê |
| --- | --- | --- |
| `server` (10.10.1.1) | `r6615` (Clemson): 1× EPYC 9354P, 32 núcleos a 3,25 GHz, ConnectX-6 100G | núcleo rápido, um só soquete (placa e núcleos no mesmo nó NUMA) |
| `client` (10.10.1.2) | `r6525` (Clemson): 2× EPYC 7543, 64 núcleos, ConnectX-6 100G | precisa gerar mais carga do que o servidor atende, inclusive em HTTPS |

Os tipos, a velocidade do link e a imagem são parâmetros do perfil.

## 1. Criar o perfil

1. Publique este diretório num repositório **público** do GitHub. O CloudLab exige
   `profile.py` na raiz e clona o repositório em `/local/repository` de cada nó.
2. No CloudLab: *Experiments → Create Experiment Profile → Git Repo*, cole a URL.
3. Depois de mudar o repositório, clique em *Update* na página do perfil.

## 2. Instanciar

*Instantiate*, confira os parâmetros e escolha o cluster de Clemson. Cada nó então:

1. instala o kernel 7.0 (`linux-generic-hwe-24.04`) e reinicia uma vez;
2. instala clang, libbpf, bpftool, perf, dwarves e os cabeçalhos do kernel;
3. **servidor:** compila o `resolve_btfids` (o módulo do xHTTP precisa dele), instala
   nginx e Go, e compila o khttpd e o hyper-fast-path dos forks usados no artigo;
4. **cliente:** compila wrk e wrk2 e os instala em `/usr/local/bin`.

Leva de 20 a 40 minutos. Acompanhe com `tail -f /local/logs/setup.log`; o nó está
pronto quando `/local/setup-state/done` existe.

## 3. Ligar os nós e clonar o xHTTP

O repositório do xHTTP é privado. O servidor o clona com a **sua** chave do GitHub,
emprestada pelo SSH (`ssh -A`, agent forwarding): nenhuma chave ou token fica no nó.
Só chega lá o que já foi para o GitHub; faça push antes. Na **sua máquina**:

```bash
eval "$(ssh-agent)" && ssh-add ~/.ssh/id_ed25519   # se o agente não estiver rodando
scripts/bootstrap.sh <host-do-servidor> <host-do-cliente> feat/tc-crypto
```

O terceiro argumento é a branch, tag ou commit (padrão `feat/tc-crypto`). Para
atualizar o servidor depois de um push, rode o script de novo. Para usar o git à mão
no servidor, entre com `ssh -A`.

Os hosts aparecem na *List View* do experimento (por exemplo
`clnode123.clemson.cloudlab.us`). Se o seu usuário no CloudLab for outro, use
`CL_USER=seu_usuario`.

O script clona o xHTTP em `~/xhttp` no servidor e compila. Também cria uma chave
SSH do servidor para o cliente, acha as interfaces de 100G e o maior anel RX da
placa, desliga o offload de TLS da placa e escreve `~/xhttp/tests/cloudlab.env`.

## 4. Rodar

No servidor, dentro de `tmux`:

```bash
cd ~/xhttp && source tests/cloudlab.env
P=cloudlab_$(date +%F)

# 1 núcleo, igual ao artigo
CUSTOM_PAYLOAD_ROUTES="1k 2k 4k 8k 16k 32k 64k 128k 256k" \
  tests/run_comparison_suite.sh 10 results/${P}_plain_c16

# multinúcleo
for n in 1 2 4 8 16; do
  NUM_CORES=$n CONCURRENCY=$((64*n)) THREADS=32 \
  CUSTOM_PAYLOAD_ROUTES="1k 16k 64k 256k" \
    tests/run_comparison_suite.sh 10 results/${P}_cores${n}
done
```

Os gráficos e o restante do fluxo estão em `docs/artigo/TUTORIAL_CLOUDLAB.md`, no
repositório do xHTTP.

Para trazer os resultados para a sua máquina:

```bash
rsync -az <usuario>@<host-do-servidor>:xhttp/results/ ~/Documents/Github/xhttp/results/
```

## Observações

- **Velocidade do link:** o carregador do xHTTP lê a velocidade da interface e
  configura o relógio de envio do módulo sozinho.
- **Offload de TLS:** o `bootstrap.sh` desliga o offload de TLS da placa, mas isso
  não sobrevive a um reboot. Rode o script de novo depois de reiniciar o servidor.
- **CPUs AMD:** o `bench_env.sh` do xHTTP desliga o boost dos dois nós pelo
  `cpufreq/boost` (além do `intel_pstate` da Intel) e o restaura no fim. Os contadores
  de DRAM e PCIe (`uncore_imc`) são só da Intel e vão sair zerados; ciclos por
  requisição não são afetados.
- **Forks dos baselines:** as versões do khttpd e do hyper-fast-path ficam no topo
  de `setup/node-setup.sh` (`KHTTPD_REF`, `FASTPATH_REF`).
