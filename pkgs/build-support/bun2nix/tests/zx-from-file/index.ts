///!dep zx@8.8.5 sha512-SNgDF5L0gfN7FwVOdEFguY3orU5AkfFZm9B5YSHog/UDHv+lvmd82ZAsOenOkQixigwH2+yyH198AwNdKhj+RA==
///!dep chalk@5.4.1 sha512-zgVZuo2WcZgfUEmsn6eO3kINexW8RAE4maiQ8QNs8CtpPCSyMiYsULR3HQYkm3w8FIA3SberyMJMSldGsW+U3w==

import { $ } from "zx";
import chalk from "chalk";

$.verbose = false;
const result = await $`echo "hello from file-based deps"`;
console.log(chalk.green(`zx + chalk: ${result.stdout.trim()}`));
