# Электронная очередь

MVP для одной площадки: клиент записывается по QR-ссылке, указывает ФИО и
сведения о поездках и даёт согласие на обработку ПДн. Авторизованный
сотрудник получает следующий совместимый талон. Администратор и аудитор
используют закрытый интерфейс с разными правами.

---

## 1. Как это работает (архитектура)

### Компоненты

| Компонент | Что делает |
|---|---|
| `apps/client-web` | Публичный интерфейс клиента: запись по QR, живая очередь (киоск), табло. |
| `apps/staff-web` | Интерфейс сотрудника / администратора / аудитора. |
| `apps/api` | NestJS API: BFF для OIDC-входа, очередь, назначение, аудит, метрики. |
| PostgreSQL | Источник истины. Талоны, сотрудники, столы, назначения, аудит. Keycloak хранит свои таблицы в отдельной схеме `keycloak`. |
| Redis | Сессии, rate-limit («3 в час»), удержание слотов, идемпотентность. |
| Keycloak | Единый вход (OIDC). Realm `ticket-system` с ролями `EMPLOYEE` / `ADMIN` / `AUDITOR`. |
| nginx | Единая точка входа: раздаёт `/client/` и `/staff/`, проксирует `/api/`, `/realms/`, `/admin/` к Keycloak. |

### Поток входа (OIDC)

1. Пользователь открывает `/staff/`, SPA редиректит на Keycloak (`/realms/ticket-system`).
2. Keycloak проверяет логин/пароль и возвращает code на `/api/auth/callback`.
3. API обменивает code на токены, кладёт сессию в Redis, ставит cookie `ticket.sid`.
4. Дальше запросы `/api/…` идут с cookie; API проверяет роли (`EMPLOYEE`, `ADMIN`, `AUDITOR`).

### Очередь и назначение

Назначение талона на сотрудника выполняется внутри транзакции PostgreSQL
(`FOR UPDATE SKIP LOCKED` + частичные уникальные индексы), поэтому один талон
или сотрудник не могут иметь два активных назначения одновременно.

### Номер талона

Номер = `код площадки` + порядковый номер **по дате слота** (не по дате
создания). Например `MAIN-001`, `MAIN-002` и т.д. в пределах одной даты слота.
Генерация идёт внутри транзакции под advisory-lock по площадке, поэтому номера
не дублируются.

### Лимит записи

Не более **3 талонов в час с одного номера телефона** (ключ — нормализованный
телефон, а не IP-адрес). Это снимает проблему, когда много клиентов
записываются из офиса за одним NAT-адресом.

---

## 2. Два вида учёток (важно не путать)

| Что открываете | Realm | Логин | Пароль |
|---|---|---|---|
| **Админ-консоль Keycloak** (`/admin/`) | `master` | `KC_BOOTSTRAP_ADMIN_USERNAME` (обычно `admin`) | `KC_BOOTSTRAP_ADMIN_PASSWORD` |
| **Приложение** (`/staff/`) | `ticket-system` | пользователь из Keycloak | его пароль |

Демо-учётки приложения (только при `NODE_ENV=development`, в production удаляются):

- администратор: `admin` / `Admin123!`
- сотрудник: `rf1` / `Employee123!`
- аудитор: `auditor` / `Auditor123!`

---

## 3. Запуск на сервере (пошагово)

### Требования

- Linux-сервер, **минимум 2 ГБ RAM**.
- Docker Engine + Compose v2 (`docker compose version`).
- Открыты TCP-порты **80** и **443** (в firewall/security group).
- Утилиты `openssl` и `curl` (обычно уже есть).

### Шаг 1. Клонировать репозиторий

```bash
git clone https://github.com/Bulat3302/ticket_system.git
cd ticket_system
```

### Шаг 2. Создать `.env`

```bash
cp .env.example .env
nano .env
```

Заполните минимум (сгенерируйте секреты командой `openssl rand -hex 32`):

```dotenv
NODE_ENV=production
# PUBLIC_ORIGIN оставьте пустым — скрипт сам определит IP и поставит https://IP
PUBLIC_ORIGIN=
WEB_HTTP_PORT=80
WEB_HTTPS_PORT=443

POSTGRES_PASSWORD=<сгенерированный>
REDIS_PASSWORD=<сгенерированный>
SESSION_SECRET=<сгенерированный>
OIDC_CLIENT_SECRET=<сгенерированный>

KC_BOOTSTRAP_ADMIN_USERNAME=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=<придумайте пароль для админки Keycloak>

STAFF_ADMIN_USERNAME=boss
STAFF_ADMIN_PASSWORD=<придумайте пароль первого админа приложения>
```

> Пароли без пробелов и символов `$` и `#`.

Если у вас есть домен, задайте `PUBLIC_ORIGIN=https://ваш.домен` и положите
доверенные `fullchain.pem` / `privkey.pem` в `infra/certs/`. Без домена скрипт
выпустит самоподписанный сертификат на IP сервера (браузер покажет
предупреждение — это нормально для IP).

### Шаг 3. Запустить

```bash
sudo bash infra/up.sh
```

Первый запуск долгий (сборка образов, первая оптимизация Keycloak). Скрипт:

1. выведет/допишет `PUBLIC_ORIGIN`;
2. выпустит самоподписанный TLS-сертификат, если нет доверенного;
3. соберёт образы по одному (keycloak → api → web);
4. поднимет стек и дождётся healthcheck;
5. применит URL клиента Keycloak, удалит демо-учётки и создаст первого админа.

### Шаг 4. Проверить

```bash
docker compose -f infra/docker-compose.yml ps
docker compose -f infra/docker-compose.yml logs keycloak
```

После запуска:

- клиент: `https://<IP>/client/`
- сотрудник/админ: `https://<IP>/staff/`
- админ-консоль Keycloak: `https://<IP>/admin/`
- OpenAPI (только development): `https://<IP>/api/docs`

### Шаг 5. Войти

1. Откройте `https://<IP>/staff/` и войдите под `STAFF_ADMIN_USERNAME` / `STAFF_ADMIN_PASSWORD` — это первый администратор приложения.
2. Откройте `https://<IP>/admin/` и войдите под `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` — это консоль Keycloak (realm `master`). Здесь создавайте сотрудников с ролями `EMPLOYEE` / `ADMIN` / `AUDITOR`.

---

## 4. Локальный запуск (development)

Для разработки на своей машине:

```dotenv
NODE_ENV=development
PUBLIC_ORIGIN=http://localhost:18080
WEB_HTTP_PORT=18080
WEB_HTTPS_PORT=18443
# ... секреты как выше ...
```

```bash
cp .env.example .env
# заполнить секреты, NODE_ENV=development, порты 18080/18443
sudo bash infra/up.sh
```

Адреса: клиент `http://localhost:18080/client/`, сотрудник
`http://localhost:18080/staff/`, Keycloak `http://localhost:18080/admin/`.
В режиме development остаются демо-учётки и включён OpenAPI.

---

## 5. Управление стеком

```bash
# остановить
docker compose -f infra/docker-compose.yml down

# остановить и удалить данные (полный сброс, необратимо)
docker compose -f infra/docker-compose.yml down -v

# логи конкретного сервиса
docker compose -f infra/docker-compose.yml logs -f api
docker compose -f infra/docker-compose.yml logs -f keycloak
```

Данные хранятся в томах `ticket-system_postgres-data` и
`ticket-system_redis-data`. Keycloak хранит всё в схеме `keycloak` внутри
PostgreSQL, поэтому отдельного тома у него нет.

### Полезное

- Перезапустить после изменения `.env`: `sudo bash infra/up.sh` (пересоздаст api/keycloak/web).
- Сбросить только пароль админа Keycloak, не трогая данные приложения:
  удалить схему `keycloak` в PostgreSQL или выполнить сброс через `kcadm`.
- Сбросить счётчики лимита записи: `docker compose -f infra/docker-compose.yml exec redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning FLUSHDB` (осторожно — очистит и сессии).

---

## 6. Что было исправлено относительно исходника

1. **Лимит «не более 3 в час»** считался по IP-адресу. Из-за общего офисного NAT
   все записи шли под одним IP и блокировались. Теперь ключ — **номер телефона**
   (`rate-limit.service.ts`, `queue.controller.ts`). Заодно удалён неиспользуемый
   мёртвый код `bindActiveTicket` / `clearActiveTicket` (писали ключ `ticket:bind:`,
   который никто не читал).
2. **Дубли номеров талонов** (пять одинаковых «030» на табло): номер считался по
   дате создания, а табло показывает по дате слота. Теперь номер считается **по
   дате слота** и проверяется на уникальность в пределах даты (`nextTicketNumber`
   в `queue.service.ts`).
3. **Единая конфигурация prod/dev**: вместо трёх compose-файлов и двух скриптов —
   один `infra/docker-compose.yml`, один `infra/up.sh` и один realm-файл.
   Различия задаются только через `.env` (`NODE_ENV`, `PUBLIC_ORIGIN`, порты,
   `STAFF_ADMIN_*`). Keycloak теперь всегда хранит данные в PostgreSQL (схема
   `keycloak`), а не в H2-томе — dev и prod поднимаются одинаково.

---

## 7. Проверки

```bash
npm run build
npm run lint
npm test
```
