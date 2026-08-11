# coolleo-display-linux

Suporte Linux experimental e não oficial para o visor de telemetria encontrado
em uma unidade testada do **MACH1 BOREAL B40S-DIG-BK-V2**. Seu comportamento
USB coincide com o ramo `1a2c:4d84` encontrado no software publicado para o
COOLLEO B40S DIG V2. O programa mostra temperatura e potência do pacote de uma
CPU Intel sem executar o aplicativo proprietário do Windows.

> **Software alfa:** o transporte do relatório USB foi reproduzido e observado
> em uma unidade física, mas ainda falta uma confirmação visual independente
> dos números exibidos. Leia a tabela de compatibilidade antes de instalar. O
> projeto não é afiliado nem endossado por COOLLEO, MACH1, SEMICO ou seus
> fornecedores. Os nomes são usados somente para identificar o hardware
> testado.

[Read in English](README.md)

## O que o programa faz

A cada dois segundos, o serviço:

1. lê `Package id 0` pelo módulo Linux `coretemp`;
2. calcula a potência média do pacote pelo Intel RAPL;
3. monta o Feature Report HID `0x07` de 64 bytes;
4. abre um dispositivo `hidraw` e confere identidade USB e o descritor exato de
   205 bytes usando o mesmo descritor de arquivo que receberá o envio;
5. envia temperatura e potência e fecha o dispositivo.

Não existe código de rede. O projeto **não** controla rotação de fan, bomba,
RGB, firmware ou BIOS e não contém nem redistribui executáveis, drivers, SDKs ou
DLLs do fabricante.

## Compatibilidade

| Componente | Situação |
|---|---|
| USB `1a2c:4d84` com o descritor exato de `src/coolleo_display.py` | Experimental; transporte validado em uma unidade |
| Ubuntu Server 24.04, Linux 6.8, Intel Core i9-11900KF | Ambiente testado no hardware |
| Outras CPUs Intel com `coretemp` e RAPL `package-0` | Deve funcionar, mas ainda não foi testado no hardware |
| CPUs AMD | Não suportadas |
| PIDs USB `1a2c:4c84` e `1a2c:4e87` | Não suportados; usam ramos diferentes do protocolo |
| USB `048d:5702` | Não é este visor; não suportado |
| Números do visor iguais aos sensores Linux | Confirmação independente pendente |

A lista exata de descritor é uma proteção deliberada. O VID `1a2c` também é
usado por periféricos semelhantes a teclados; VID/PID sozinho não é autorização
segura para escrever em USB.

## Requisitos

- Linux com systemd, udev e `hidraw`;
- Python 3.9 ou superior, sem pacotes adicionais;
- CPU Intel com `coretemp` e Intel RAPL `package-0`;
- dispositivo USB interno testado conectado;
- acesso root para instalar.

## Instalação

Clone o repositório, entre na pasta, confira os scripts e instale:

```bash
git clone https://github.com/NGK-999/coolleo-display-linux.git
cd coolleo-display-linux
sudo ./scripts/install.sh
```

O instalador faz uma verificação somente de leitura antes de ativar o serviço.
Se o cooler estiver propositalmente desconectado, é possível instalar com:

```bash
sudo ./scripts/install.sh --allow-missing-display
```

Nesse modo, o serviço registra um erro curto e tenta novamente quando o
hardware aparecer. Não use `--force` sem analisar o arquivo citado no erro: a
opção autoriza explicitamente substituir, após backup, um arquivo desconhecido
ou modificado localmente.

## Verificação e uso

Diagnóstico somente de leitura, sem enviar relatório USB:

```bash
sudo /usr/local/bin/coolleo-display --check --interval 1
```

Estado e logs recentes:

```bash
sudo systemctl status coolleo-display.service --no-pager
sudo journalctl -u coolleo-display.service -n 30 --no-pager
```

Um único envio controlado:

```bash
sudo systemctl stop coolleo-display.service
sudo /usr/local/bin/coolleo-display --once --interval 1
sudo systemctl start coolleo-display.service
```

Compare `display_temperature` e `display_power` impressos pelo comando
`--once` com o visor físico. Os valores decimais são as amostras dos sensores e
são truncados de propósito para o relatório de três dígitos. Leia
[`docs/SUPPORT.md`](docs/SUPPORT.md) antes de relatar diferença.

## Desinstalação e reversão

Na mesma cópia do repositório:

```bash
sudo ./scripts/uninstall.sh
```

O desinstalador confere os hashes, para o serviço, exige que a restauração do
dono e modo salvos do Intel RAPL termine sem erro, restringe o nó atual do visor
e devolve os arquivos que existiam antes. Os backups permanecem em
`/var/lib/coolleo-display/backups`.

Para apagar também esses backups de forma irreversível:

```bash
sudo ./scripts/uninstall.sh --purge
```

`--force` permite remover arquivos alterados depois da instalação; revise-os
antes. Você também pode executar `--purge` mais tarde, a partir do mesmo clone,
depois que uma desinstalação normal já tiver removido a aplicação.

## Segurança e limitações

- não usa rede nem dependências Python externas;
- executa com usuário de sistema sem privilégios;
- usa regra udev estreita e valida o mesmo descritor aberto antes de escrever;
- envia somente o relatório de telemetria conhecido;
- preserva e restaura permissões do Intel RAPL;
- aplica isolamento systemd;
- recusa sobrescrever arquivos desconhecidos por padrão.

Leia [`SECURITY.md`](SECURITY.md) e
[`docs/PROTOCOL.md`](docs/PROTOCOL.md). Problemas e evidências de outro hardware
são bem-vindos, mas não envie binários do fabricante, comandos adivinhados ou
operações de firmware. Veja [`CONTRIBUTING.md`](CONTRIBUTING.md).

Criado por Igor com desenvolvimento assistido por IA, revisão do protocolo,
testes automatizados e validação na unidade original do laboratório. A situação
de validação declarada acima é a referência; assistência por IA não é tratada
como prova de funcionamento.

Licenciado sob a [Licença MIT](LICENSE).
