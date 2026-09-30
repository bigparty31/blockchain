/**
 * 함수별 가스 사용량 집계. hardhat-gas-reporter 가 Hardhat 3 를 지원하지 않아 receipt 에서 직접 모은다.
 * 테스트에서 `await gas("label", tx)` 로 감싸면 마지막에 표로 출력한다. 같은 label 은 min / avg / max 를 낸다.
 */

const samples = new Map<string, number[]>();

export async function gas<T>(label: string, txPromise: Promise<T> | T): Promise<T> {
  const tx: any = await txPromise;
  const receipt = await tx.wait();
  const used = Number(receipt.gasUsed);
  const list = samples.get(label) ?? [];
  list.push(used);
  samples.set(label, list);
  return tx;
}

export function gasTable(): Array<{ function: string; calls: number; min: number; avg: number; max: number }> {
  return [...samples.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([label, list]) => ({
      function: label,
      calls: list.length,
      min: Math.min(...list),
      avg: Math.round(list.reduce((s, v) => s + v, 0) / list.length),
      max: Math.max(...list),
    }));
}

after(function () {
  if (samples.size === 0) return;
  console.log("\n가스 사용량 (receipt.gasUsed)");
  console.table(gasTable());
});
