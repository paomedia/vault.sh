# vault.sh
- Simple Bash CLI, self-contained password manager.
- Should work on most Linux/Unix based systems.
- Require `bash` >= 4.4

## Features
- AES 256 encrypted
- Customizable strong password generation
- Passwords and Data are embeded in source code (weird ?)
- You can have multiple vaults just changing the filename
- ...

## Setup

- Download vault.sh
- Rename it if you want
- Chmod it +x to make it executable
- Put it in your ~/bin directory, on a usb stick or anywhere you want
- Masterkey (main password) will be set on your first use

### Example

```
$ curl -fsSL https://u2l.ai/D4teUa -o myvault
$ chmod +x myvault
$ ./myvault add
```
 
## Main commands

- vault.sh add
- vault.sh show
- vault.sh delete
- vault.sh update


## Usage

```
USAGE
  vault.sh COMMAND [ARG]...

COMMANDS
  add                add new account
  clearmk [-r|-h]    remove cached master key (both if no option given)
  delete SERVICE     delete account by SERVICE name
  dump [--decrypt]   display database as json (--decrypt requires jq)
  genpasswd [...]    display a random generated password
  help, -h, --help   display this help and exit
  import             import accounts from a vault dump on stdin
  reset              erase database, reinit
  savemk -r|-h       save master key in ram or home for future use
  show [KEYWORD]     display accounts that match KEYWORD
  update SERVICE     update account fields (blank keeps current value)
  version            output version information and exit

IMPORT USAGE
  /path/to/other-vault dump --decrypt | vault.sh import
  vault.sh import < dump.json

SAVEMK USAGE
  vault.sh savemk -r|-h

  -r, --ram          save master key temporarily in ram
                     mk will be in /run/user/<uid>/vault-<vault-id>.mk
  -h, --home         save master key permanently
                     mk will be in ~/.vault-<vault-id>.mk

CLEARMK USAGE
  vault.sh clearmk [-r|-h]

  -r, --ram          remove only the ram-cached master key
  -h, --home         remove only the home-cached master key
  (no option)        remove both

GENPASSWD USAGE
  vault.sh genpasswd [LEN [LC [UC [SPEC [NUM]]]]]

  LEN                password length (default=16)
  LC                 minimum lowercase chars (default=6)
  UC                 exact uppercase chars (default=6)
  SPEC               exact special chars (default=2)
  NUM                exact numerical chars (default=2)
```

## Security notice

`savemk` writes your master key to disk in **plain text** (file mode 0400,
owner-readable only, but that's no protection against root, another process
running as you, or a backup/snapshot of the file). Anyone who reads that file
has full access to your vault, no master key guessing required. `--ram`
(tmpfs) is safer than `--home` (persists across reboots) but still readable
for as long as it's cached. Use `clearmk` when you're done, and think twice
about `--home` on a shared or otherwise untrusted machine.

