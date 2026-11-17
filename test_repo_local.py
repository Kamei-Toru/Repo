#!/usr/bin/env python3
# Version: 1.7a
"""Run the isolated configuration and repository integration suite."""
import sys
SCRIPT_VERSION = "1.7a"
if __name__ == '__main__' and '--version' in sys.argv[1:]:
    print(f'test_repo_local.py {SCRIPT_VERSION}')
    raise SystemExit(0)

import unittest
from test_repo_config import ConfigurationTests

if __name__ == '__main__':
    unittest.main()
