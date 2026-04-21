# Інфраструктура для локального запуску

Цей документ описує, як підняти мінімальну інфраструктуру для `parcs-lab-go`:
- Docker Swarm,
- overlay network `parcs`,
- `docker-proxy` сервіс для доступу контейнерів до Docker API.

## 1) Передумови

Потрібно:
- Docker Desktop або Docker Engine,
- доступ до Docker CLI з поточного користувача.

Швидка перевірка:

```bash
docker version
docker info
```

## 2) Підняти інфраструктуру (up)

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

## 3) Перевірити стан інфраструктури

```bash
docker info --format '{{.Swarm.LocalNodeState}}'
docker network ls --filter name=parcs
docker service ls --filter name=docker-proxy
```

За потреби подивись логи proxy:

```bash
docker service logs docker-proxy
```

## 4) Використання з запуском задачі

Після підняття інфраструктури запускай solver так:

```bash
LEADER_URL='tcp://docker-proxy:4321' \
SKIP_PUSH=1 \
./scripts/run.sh
```

## 5) Зупинка/очистка (down)

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
