import { keccak256, concat, pad, toHex, getAddress } from "viem";

const CREATEX  = "0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed";
const INITHASH = process.argv[2];
const PREFIX   = (process.argv[3] || "ec0").toLowerCase();
const MAX      = Number(process.argv[4] || 5_000_000);

// Unguarded CreateX salt: first 20 bytes zero, byte 20 zero, remaining 11 bytes are free entropy.
function saltFor(i) { return pad(toHex(i), { size: 32 }); }

const t0 = Date.now();
for (let i = 1; i < MAX; i++) {
  const salt = saltFor(i);
  const guarded = keccak256(salt);                       // keccak(abi.encode(bytes32 x)) === keccak(x)
  const addr = "0x" + keccak256(concat(["0xff", CREATEX, guarded, INITHASH])).slice(-40);
  if (addr.slice(2).toLowerCase().startsWith(PREFIX)) {
    const secs = ((Date.now() - t0) / 1000).toFixed(2);
    console.log(`found after ${i.toLocaleString()} tries in ${secs}s`);
    console.log(`  salt : ${salt}`);
    console.log(`  addr : ${getAddress(addr)}`);
    process.exit(0);
  }
}
console.log("no match within limit");
