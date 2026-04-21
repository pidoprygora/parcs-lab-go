# PARCS-Go Gauss Solver: Як користуватись

## 1) Що це

Цей проєкт розв'язує системи лінійних рівнянь методом Гауса в Docker Swarm, використовуючи PARCS SDK для Go.

Компоненти:
- `gauss-runner` — координатор обчислень.
- `gauss-worker` — воркер, який виконує елімінацію блоку рядків.
- `scripts/run.sh` — скрипт для build/push/run і перегляду логів.

## 2) Підняття інфраструктури

Повний покроковий гайд винесено в `docs/infrastructure.md`:
- ініціалізація Docker Swarm,
- створення overlay network `parcs`,
- запуск `docker-proxy`,
- перевірка стану,
- зупинка та очистка.

Для запуску `run.sh` і `experiments.sh` потрібен `LEADER_URL=tcp://docker-proxy:4321`.

## 3) Запуск скриптів

Окремий гайд по запуску скриптів дивись у `docs/scripts.md`:
- як запускати `scripts/run.sh`,
- як запускати `scripts/experiments.sh`,
- параметри, приклади і типові помилки.

## 4) Передумови

Потрібно встановити:
- Docker Desktop або Docker Engine
- Увімкнений Docker Swarm
- Overlay network `parcs`

Швидка ініціалізація:

```bash
docker swarm init
docker network create -d overlay parcs
```

## 5) Налаштування доступу до Docker API з контейнерів

PARCS-Go запускає дочірні Docker Services з контейнера `gauss-runner`, тому йому потрібен доступ до Docker API.

Практичний варіант для локального запуску:

```bash
docker service create \
  --name docker-proxy \
  --network parcs \
  --restart-condition any \
  --mount type=bind,src="/Users/$USER/.docker/run/docker.sock",dst=/var/run/docker.sock \
  alpine/socat tcp-listen:4321,fork,reuseaddr unix-connect:/var/run/docker.sock
```

Після цього як `LEADER_URL` використовуй:

```bash
tcp://docker-proxy:4321
```

## 6) Базовий запуск

З кореня проєкту:

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SKIP_PUSH=1 \
REGISTRY_NAMESPACE=local \
WORKER_IMAGE_NAME=gauss-worker \
RUNNER_IMAGE_NAME=gauss-runner \
NUM_WORKERS=2 \
MATRIX='[[2,1,-1,8],[-3,-1,2,-11],[-2,1,2,-3]]' \
SERVICE_NAME='gauss-runner-lab' \
./scripts/run.sh
```

Очікуваний результат у логах:
- `x[0] = 2.00000000`
- `x[1] = 3.00000000`
- `x[2] = -1.00000000`

## 7) Формат вхідних даних

Вхід передається через `MATRIX` як JSON масив розширеної матриці `[A|b]`.

Для системи `n x n`:
- має бути `n` рядків
- у кожному рядку має бути `n + 1` елементів

Приклад 3x3:

```text
[[2,1,-1,8],[-3,-1,2,-11],[-2,1,2,-3]]
```

## 8) Основні параметри `run.sh`

Обов'язковий:
- `LEADER_URL` — адреса Docker API для PARCS (`tcp://...:4321`)

Необов'язкові:
- `REGISTRY_NAMESPACE` (default: `local`)
- `WORKER_IMAGE_NAME` (default: `gauss-worker`)
- `RUNNER_IMAGE_NAME` (default: `gauss-runner`)
- `IMAGE_TAG` (default: `latest`)
- `NUM_WORKERS` (default: `2`)
- `MATRIX` (default: тестовий 3x3 приклад)
- `SERVICE_NAME` (default: `gauss-runner`)
- `SKIP_PUSH=1` — не пушити образи в registry

## 9) Корисні команди

Перевірити стан Swarm:

```bash
docker info --format '{{.Swarm.LocalNodeState}}'
```

Перегляд логів runner:

```bash
docker service logs -f gauss-runner-lab
```

Прибрати сервіси:

```bash
docker service rm gauss-runner-lab docker-proxy
```

## 10) Типові проблеми

- `WORKER_IMAGE env var is required`  
  Перевір, що запуск іде через `scripts/run.sh` або передано `WORKER_IMAGE`.

- `MATRIX env var is required` або помилка JSON  
  Перевір синтаксис JSON та лапки у shell.

- `singular or near-singular matrix`  
  Матриця вироджена або близька до виродженої.

- Runner не може стартувати worker-сервіси  
  Перевір `LEADER_URL` і доступність Docker API (див. секцію про `docker-proxy`).
