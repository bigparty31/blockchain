-- 학생 서버용 읽기 전용 DB 계정 (PRD §9.1, docs/SERVER_ENV.md §5)
--
-- 학생 서버는 조회 전용이다. 릴레이어 키를 주지 않는 것과 같은 이유로 DB 도 읽기만
-- 하게 묶는다 — 학생 서버가 뚫려도 원장을 고칠 수 없어야 한다. 키만 막고 DB 를 열어
-- 두면 "학생 서버는 읽기 전용"이라는 말이 반만 참이 된다.
--
-- **마이그레이션 뒤에 실행한다.** 테이블이 있어야 GRANT 가 걸린다:
--
--   docker compose exec -T api alembic upgrade head
--   export $(grep -E '^STUDENT_DB_PASSWORD=' .env | xargs)   # .env 는 compose 만 읽는다
--   docker compose exec -T db psql -U council -d council \
--     -v student_ro_password="$STUDENT_DB_PASSWORD" -f /dev/stdin < deploy/student-ro.sql
--
-- **값에 따옴표를 붙이지 않는다.** 아래 `:'student_ro_password'` 가 인용까지 하므로,
-- `-v x="'pw'"` 로 주면 따옴표까지 비밀번호에 들어가 **앱만 로그인에 실패한다** —
-- 컨테이너 안에서 `psql -h 127.0.0.1` 로 해 보면 그쪽은 pg_hba 가 trust 라 통과해서
-- 비밀번호가 맞는 것처럼 보인다.
--
-- 여러 번 실행해도 안전하다 (역할이 있으면 비밀번호만 갱신).

\set ON_ERROR_STOP on

-- 역할. 이미 있으면 비밀번호만 바꾼다 — 재실행으로 깨지지 않게.
--
-- `DO $$ ... $$` 안에서는 psql 변수(`:'...'`)가 치환되지 않아 쓸 수 없다.
-- 문장을 만들어 `\gexec` 로 실행한다.
SELECT format('CREATE ROLE student_ro LOGIN PASSWORD %L', :'student_ro_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'student_ro')
\gexec

SELECT format('ALTER ROLE student_ro WITH LOGIN PASSWORD %L', :'student_ro_password')
\gexec

GRANT CONNECT ON DATABASE council TO student_ro;
GRANT USAGE ON SCHEMA public TO student_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO student_ro;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO student_ro;

-- 앞으로 생길 테이블에도 조회 권한이 가게 한다. 마이그레이션이 테이블을 더 만들어도
-- 학생 서버 조회가 깨지지 않는다.
ALTER DEFAULT PRIVILEGES FOR ROLE council IN SCHEMA public
  GRANT SELECT ON TABLES TO student_ro;
ALTER DEFAULT PRIVILEGES FOR ROLE council IN SCHEMA public
  GRANT SELECT ON SEQUENCES TO student_ro;

-- **login_attempts 하나만 쓰기를 연다** (#89, PRD §9.1).
-- 학생 서버의 POST /auth/login 이 연속 실패 횟수를 여기에 쓴다. 학생 서버가 여러 대여도
-- 합쳐 세야 해서 DB 에 남긴다. 이 권한이 없으면 **학생 로그인이 전부 503** 이다
-- (permission denied for table login_attempts).
-- 시퀀스 권한은 주지 않는다 — 이 표의 PK 는 `student_no` 라 시퀀스가 없다.
GRANT INSERT, UPDATE, DELETE ON login_attempts TO student_ro;
