import { defineConfig } from "hardhat/config";
import hardhatToolboxMochaEthers from "@nomicfoundation/hardhat-toolbox-mocha-ethers";

// 소스는 두 곳이다. interfaces/ 는 정본 인터페이스(docs 가 이 경로를 참조), src/ 는 구현.
export default defineConfig({
  plugins: [hardhatToolboxMochaEthers],
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  paths: {
    sources: ["./interfaces", "./src"],
    tests: "./test",
  },
  networks: {
    // hardhat node 를 따로 띄운 뒤 배포 스크립트가 붙는 대상. 개인키는 Hardhat 기본 계정만 쓴다.
    localhost: {
      type: "http",
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },
  },
});
