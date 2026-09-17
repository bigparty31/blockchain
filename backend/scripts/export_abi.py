"""contracts/interfaces 의 .sol 에서 ABI 를 뽑아 backend/app/chain/abi/ 에 쓴다.

인터페이스가 바뀌면 다시 돌리고 결과 JSON 을 함께 커밋한다. 구현(Hardhat)이 나오면 한 번 더 돌린다
— 구현에만 있는 에러(OpenZeppelin 등)가 더해질 수 있어서다.

IMembershipSBT 가 OpenZeppelin IERC721 을 import 한다. 저장소 루트에 node_modules/@openzeppelin/contracts 가 있으면
그것을 쓰고, 없으면 OZ_VERSION 의 필요한 파일만 임시 폴더로 받는다.

    cd backend
    pip install -r requirements-dev.txt
    python scripts/export_abi.py
"""
import json
import tempfile
from pathlib import Path

import requests  # py-solc-x 의존성. certifi 인증서를 써서 macOS python.org 빌드에서도 https 가 된다
import solcx

SOLC_VERSION = "0.8.24"  # 인터페이스의 pragma ^0.8.24
OZ_VERSION = "v5.0.2"
OZ_FILES = ("token/ERC721/IERC721.sol", "utils/introspection/IERC165.sol")
INTERFACES = ("IAccountingLedger", "IBudgetToken", "IRoleManager", "IObjectionRegistry", "IMembershipSBT")

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "backend" / "app" / "chain" / "abi"


def openzeppelin_root(tmp: Path) -> Path:
    """@openzeppelin 이 들어 있는 폴더."""
    local = ROOT / "node_modules"
    if (local / "@openzeppelin" / "contracts").is_dir():
        return local
    for name in OZ_FILES:
        url = f"https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/{OZ_VERSION}/contracts/{name}"
        path = tmp / "@openzeppelin" / "contracts" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        path.write_bytes(response.content)
    return tmp


def main() -> None:
    solcx.install_solc(SOLC_VERSION)
    with tempfile.TemporaryDirectory() as tmp:
        oz = openzeppelin_root(Path(tmp))
        sources = [str(ROOT / "contracts" / "interfaces" / f"{name}.sol") for name in INTERFACES]
        compiled = solcx.compile_files(
            sources,
            output_values=["abi"],
            solc_version=SOLC_VERSION,
            import_remappings=[f"@openzeppelin/={oz / '@openzeppelin'}/"],
            allow_paths=[str(ROOT), str(oz)],
        )
    OUT.mkdir(exist_ok=True)
    for key, value in compiled.items():
        name = key.rsplit(":", 1)[1]
        if name in INTERFACES:
            path = OUT / f"{name}.json"
            path.write_text(json.dumps(value["abi"], indent=2) + "\n", encoding="utf-8")
            print(f"{path.relative_to(ROOT)}  ({len(value['abi'])} items)")


if __name__ == "__main__":
    main()
