// config.example.json을 바탕으로 config.json을 만들고 랜덤 토큰을 채운다. 이미 있으면 건드리지 않는다.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const target = path.join(ROOT, "config.json");

if (existsSync(target)) {
  console.log("config.json이 이미 있어서 그대로 둡니다.");
} else {
  const cfg = JSON.parse(readFileSync(path.join(ROOT, "config.example.json"), "utf8"));
  cfg.token = randomBytes(24).toString("base64url");
  writeFileSync(target, JSON.stringify(cfg, null, 2) + "\n");
  console.log("config.json을 만들었습니다. workspaces의 경로를 내 폴더에 맞게 고쳐 주세요.");
}
