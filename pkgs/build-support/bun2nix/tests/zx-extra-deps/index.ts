import { $ } from "zx";
import chalk from "chalk";
$.verbose = false;
const result = await $`echo "hello"`;
console.log(chalk.green(`zx + chalk: ${result.stdout.trim()}`));
