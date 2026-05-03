# Інфраструктура

Проєкт підтримує два варіанти розгортання:
- **Локально** — Docker Swarm на своїй машині.
- **AWS EC2** — одна інстанція, розгорнута через Terraform; управління і запуск через SSM.

---

## Варіант 1: Локальний Docker Swarm

Цей варіант описує, як підняти мінімальну інфраструктуру для `parcs-lab-go`:
- Docker Swarm,
- overlay network `parcs`,
- `docker-proxy` сервіс для доступу контейнерів до Docker API.

### Передумови

Потрібно:
- Docker Desktop або Docker Engine,
- доступ до Docker CLI з поточного користувача.

Швидка перевірка:

```bash
docker version
docker info
```

### Крок 1. Ініціалізувати Swarm

Перевір стан:

```bash
docker info --format '{{.Swarm.LocalNodeState}}'
```

Якщо не `active`, ініціалізуй:

```bash
docker swarm init
```

### Крок 2. Створити мережу `parcs`

```bash
docker network inspect parcs >/dev/null 2>&1 || docker network create -d overlay parcs
```

### Крок 3. Запустити `docker-proxy`

Видали старий сервіс (якщо вже є), потім створи заново:

```bash
docker service rm docker-proxy >/dev/null 2>&1 || true

docker service create \
  --name docker-proxy \
  --network parcs \
  --restart-condition any \
  --mount type=bind,src="/Users/$USER/.docker/run/docker.sock",dst=/var/run/docker.sock \
  alpine/socat tcp-listen:4321,fork,reuseaddr unix-connect:/var/run/docker.sock
```

> Для `LEADER_URL` використовуй `tcp://docker-proxy:4321`.

### Перевірити стан інфраструктури

```bash
docker info --format '{{.Swarm.LocalNodeState}}'
docker network ls --filter name=parcs
docker service ls --filter name=docker-proxy
```

За потреби подивись логи proxy:

```bash
docker service logs docker-proxy
```

### Запуск задачі після підняття

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SKIP_PUSH=1 \
./scripts/run.sh
```

### Зупинка / очистка

Прибрати сервіси:

```bash
docker service rm gauss-runner docker-proxy >/dev/null 2>&1 || true
```

Прибрати мережу:

```bash
docker network rm parcs >/dev/null 2>&1 || true
```

Вийти зі Swarm (опційно):

```bash
docker swarm leave --force
```

---

## Варіант 2: AWS EC2 через Terraform

Terraform (`infrastructure/`) розгортає одну EC2-інстанцію, яка:
- є single-node Docker Swarm,
- має overlay network `parcs` і сервіс `docker-proxy` (запускаються в `user_data`),
- клонує репозиторій з GitHub через токен із AWS SSM Parameter Store,
- доступна тільки через **AWS Systems Manager (SSM)** — жодного SSH / відкритого порту.

### Передумови (локально)

- AWS CLI v2 + плагін `session-manager-plugin`
- Terraform >= 1.6
- AWS-акаунт з правами на EC2, IAM, SSM
- Збережений GitHub Personal Access Token у SSM Parameter Store

### Крок 1. Зберегти GitHub токен у SSM

Виконати один раз перед `terraform apply`:

```bash
aws ssm put-parameter \
  --name "/parcs-lab/github-token" \
  --value "ghp_xxxxxxxxxxxxxxxxxxxx" \
  --type SecureString
```

Токен повинен мати скоуп `repo` для клонування приватного репозиторію.

### Крок 2. Налаштувати змінні

Заповни `infrastructure/terraform.tfvars`:

```hcl
aws_region            = "eu-north-1"
instance_type         = "t3.medium"   # 2 vCPU / 4 GB — для NUM_WORKERS=4-8
repo_url              = "https://github.com/<your-org>/parcs-lab-go.git"
github_token_ssm_path = "/parcs-lab/github-token"
```

Типи інстанцій:
- `t3.small` — 2 vCPU / 2 GB, підходить для `NUM_WORKERS=2-4`
- `t3.medium` — 2 vCPU / 4 GB, підходить для `NUM_WORKERS=4-8`

### Крок 3. Розгорнути інфраструктуру

```bash
cd infrastructure
terraform init
terraform apply
```

Terraform виводить:
- `instance_id` — ID EC2-інстанції
- `ssm_session_command` — готова команда для інтерактивної shell через SSM
- `run_experiments_command` — команда для запуску всіх експериментів

### Крок 4. Запустити експерименти на EC2

З директорії `infrastructure/`:

```bash
# Усі експерименти
./run-experiments.sh

# Один конкретний
EXPERIMENT=case1000_w4 ./run-experiments.sh
```

Скрипт:
1. Зчитує `instance_id` і `region` з `terraform output`.
2. Надсилає shell-скрипт через `aws ssm send-command` (AWS-RunShellScript).
3. На EC2: `git fetch && git reset --hard origin/main`, потім `scripts/experiments.sh`.
4. Поллить статус команди і виводить `stdout`/`stderr`.
5. Зберігає лог у `logs/<timestamp>_<experiment>.log`.

Опціональні змінні:

| Змінна           | Дефолт                       | Опис                                   |
|------------------|------------------------------|----------------------------------------|
| `EXPERIMENT`     | `all`                        | Ім'я кейсу або `all`                   |
| `AWS_REGION`     | береться з `terraform output` | Регіон AWS                             |
| `AWS_PROFILE`    | —                            | Профіль AWS credentials                |
| `POLL_INTERVAL`  | `5`                          | Секунди між перевірками статусу SSM    |
| `COMMAND_TIMEOUT`| `600`                        | Таймаут SSM-команди (секунди)          |

### Підключення через SSM (інтерактивна shell)

```bash
aws ssm start-session --target <instance_id> --region eu-north-1
```

Або скористайся командою з `terraform output ssm_session_command`.

### Знищити інфраструктуру

```bash
cd infrastructure
terraform destroy
```
