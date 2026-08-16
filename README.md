# linux-scripts

My personal collection of Linux automation scripts.

These are scripts I use to automate setup and maintenance tasks on my own
machines. They are shared as-is in case they're useful to others.

## Contents

- `networking/install-ipset-blacklist-debian13.sh` — installs and configures an
  ipset-based IP blacklist on Debian 13.
- `debian/install-guacamole.sh` — installs Apache Guacamole (guacd + web app +
  PostgreSQL) under `/opt/guacamole` with Docker Compose on Debian 13. Installs
  Docker if needed, replaces the stock `guacadmin` password before the web app
  is ever reachable, and writes the credentials and a log next to the script.
  Safe to re-run.

## No warranty

These scripts are provided **as-is**, with **no warranty** of any kind. Use them
at your own risk. Always review a script before running it, especially anything
that requires root privileges or modifies system configuration.

## License

Released under the [MIT License](LICENSE).
