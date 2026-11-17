// 학생 서버 부하 시험 — 결산 공개 푸시 직후 1~2분을 흉내 낸다.
//
//   k6 run -e BASE=http://127.0.0.1:8001 deploy/k6/read_mix.js
//
// 사이징 근거 (서버-분리-설계안 §3): 등록 학생 1,000명 · 피크 동시 150 · 목표 p95 300ms.
// 캐시 켜고/끈 두 번을 같은 스크립트로 돌려 비교한다 (deploy/README.md).

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://127.0.0.1:8001';
const STUDENT_NO = __ENV.STUDENT_NO || '20240001';
const PASSWORD = __ENV.PASSWORD || 'userPassword123!';

// 엔드포인트별로 따로 본다 — 평균만 보면 느린 하나가 빠른 셋에 묻힌다
const byEndpoint = {
  entries: new Trend('dur_entries', true),
  balance: new Trend('dur_balance', true),
  budgets: new Trend('dur_budgets', true),
  detail: new Trend('dur_entry_detail', true),
};

export const options = {
  stages: [
    { duration: '30s', target: 150 }, // 푸시 직후 몰리는 구간
    { duration: '1m', target: 150 },  // 피크 유지
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<300'], // 목표 p95 300ms
  },
};

// 토큰은 한 번만 받는다. 로그인까지 부하에 넣으면 bcrypt 비용이 조회 수치를 가린다
// (로그인 자체의 부하는 따로 재야 할 별개 시나리오다).
export function setup() {
  const res = http.post(
    `${BASE}/auth/login`,
    JSON.stringify({ student_no: STUDENT_NO, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json' } },
  );
  if (res.status !== 200) {
    throw new Error(`로그인 실패 ${res.status}: ${res.body}`);
  }
  const token = res.json('access_token');

  // 상세 조회에 쓸 항목 id — 시드 데이터에 따라 달라지므로 목록에서 집어 온다
  const list = http.get(`${BASE}/entries`, { headers: { Authorization: `Bearer ${token}` } });
  const ids = list.status === 200 ? list.json().map((e) => e.id) : [];
  if (ids.length === 0) {
    throw new Error('내역이 비어 있다. 시드를 먼저 넣어야 측정이 의미가 있다');
  }
  return { token, ids };
}

export default function (data) {
  const headers = { Authorization: `Bearer ${data.token}` };

  // 학생이 실제로 하는 순서에 가깝게 — 대시보드를 열면 셋이 한꺼번에 나가고,
  // 그중 일부만 상세로 들어간다
  const dash = http.batch([
    ['GET', `${BASE}/balance`, null, { headers, tags: { name: 'balance' } }],
    ['GET', `${BASE}/entries`, null, { headers, tags: { name: 'entries' } }],
    ['GET', `${BASE}/budgets`, null, { headers, tags: { name: 'budgets' } }],
  ]);
  byEndpoint.balance.add(dash[0].timings.duration);
  byEndpoint.entries.add(dash[1].timings.duration);
  byEndpoint.budgets.add(dash[2].timings.duration);
  dash.forEach((r) => check(r, { '대시보드 200': (x) => x.status === 200 }));

  // 3명 중 1명꼴로 항목 하나를 열어 본다
  if (Math.random() < 0.33) {
    const id = data.ids[Math.floor(Math.random() * data.ids.length)];
    const detail = http.get(`${BASE}/entries/${id}`, { headers, tags: { name: 'entry_detail' } });
    byEndpoint.detail.add(detail.timings.duration);
    check(detail, { '상세 200': (r) => r.status === 200 });
  }

  sleep(1 + Math.random()); // 화면을 보는 시간
}
