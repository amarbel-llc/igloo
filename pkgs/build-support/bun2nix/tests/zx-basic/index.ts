import { $ } from "zx";
$.verbose = false;
const result = await $`echo "zx works"`;
console.log(result.stdout.trim());
