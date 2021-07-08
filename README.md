# Arch Desktop autoinstall script

It's tailored just for my needs, so I really wouldn't advice to use it. You can pick some ideas from it though for your own autoinstall scripts.

Installs the system into a full-encrypted disk.

Uses UEFI, graphical environment is sway.

After being run produces a fully functional system that you can just use.

# Usage

	Usage: ./install.sh [options]
	-d  | --disk — specify disk where the system will be installed [required]
	-s  | --stage — specify installation stage. For internal usage
	-rp | --root-pass — specify root password [required]
	-up | --user-pass — specify user password [required]
	-lp | --luks-pass — specify luks password [required]
	-h  | --help — print this message
