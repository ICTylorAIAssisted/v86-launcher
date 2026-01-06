#!/usr/bin/env python3
"""
VM Launcher Asset Encryption Tool (Python)

Encrypts files using AES-256-GCM for use with the VM Launcher.
The encrypted format is compatible with the browser's Web Crypto API.

Requirements:
    pip install cryptography

Usage:
    python encrypt_assets.py encrypt <input-file> <output-file> <password>
    python encrypt_assets.py decrypt <input-file> <output-file> <password>
    python encrypt_assets.py batch <input-dir> <output-dir> <password>
    python encrypt_assets.py genkey [length]
    python encrypt_assets.py verify <encrypted-file> <password>

Example:
    python encrypt_assets.py encrypt exercise.iso exercise.iso.enc mySecretKey
"""

import os
import sys
import secrets
import string
import argparse
import tempfile
from pathlib import Path

try:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.backends import default_backend
except ImportError:
    print("Error: cryptography library not found.")
    print("Install it with: pip install cryptography")
    sys.exit(1)


# Constants - must match the browser implementation
MAGIC_HEADER = b'VMENC1'
SALT = b'vm-launcher-salt-v1'
ITERATIONS = 100000
KEY_LENGTH = 32  # 256 bits
IV_LENGTH = 12   # 96 bits for GCM


def derive_key(password: str) -> bytes:
    """Derive encryption key from password using PBKDF2."""
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=KEY_LENGTH,
        salt=SALT,
        iterations=ITERATIONS,
        backend=default_backend()
    )
    return kdf.derive(password.encode('utf-8'))


def encrypt_file(input_path: str, output_path: str, password: str) -> int:
    """Encrypt a file and return the output size."""
    print(f"Encrypting: {input_path}")
    
    # Read input file
    with open(input_path, 'rb') as f:
        plaintext = f.read()
    
    input_size = len(plaintext)
    print(f"  Input size: {input_size / 1024 / 1024:.2f} MB")
    
    # Derive key
    key = derive_key(password)
    
    # Generate random IV
    iv = secrets.token_bytes(IV_LENGTH)
    
    # Create cipher and encrypt
    aesgcm = AESGCM(key)
    ciphertext = aesgcm.encrypt(iv, plaintext, None)
    
    # Build output: MAGIC_HEADER + IV + ciphertext (includes auth tag)
    output = MAGIC_HEADER + iv + ciphertext
    
    # Write output
    with open(output_path, 'wb') as f:
        f.write(output)
    
    output_size = len(output)
    print(f"  Output size: {output_size / 1024 / 1024:.2f} MB")
    print(f"  Written to: {output_path}")
    
    return output_size


def decrypt_file(input_path: str, output_path: str, password: str) -> int:
    """Decrypt a file and return the output size."""
    print(f"Decrypting: {input_path}")
    
    # Read encrypted file
    with open(input_path, 'rb') as f:
        encrypted = f.read()
    
    print(f"  Input size: {len(encrypted) / 1024 / 1024:.2f} MB")
    
    # Verify magic header
    header = encrypted[:6]
    if header != MAGIC_HEADER:
        raise ValueError("Invalid file format - missing magic header")
    
    # Extract components
    iv = encrypted[6:6 + IV_LENGTH]
    ciphertext = encrypted[6 + IV_LENGTH:]
    
    # Derive key
    key = derive_key(password)
    
    # Create cipher and decrypt
    aesgcm = AESGCM(key)
    try:
        plaintext = aesgcm.decrypt(iv, ciphertext, None)
    except Exception as e:
        raise ValueError(f"Decryption failed - wrong password or corrupted file: {e}")
    
    # Write output
    with open(output_path, 'wb') as f:
        f.write(plaintext)
    
    output_size = len(plaintext)
    print(f"  Output size: {output_size / 1024 / 1024:.2f} MB")
    print(f"  Written to: {output_path}")
    
    return output_size


def batch_encrypt(input_dir: str, output_dir: str, password: str):
    """Batch encrypt all files in a directory."""
    input_path = Path(input_dir)
    output_path = Path(output_dir)
    
    print(f"Batch encrypting: {input_dir} -> {output_dir}")
    
    # Create output directory if needed
    output_path.mkdir(parents=True, exist_ok=True)
    
    # Get all files
    total_input = 0
    total_output = 0
    count = 0
    
    for file_path in input_path.iterdir():
        if file_path.is_file():
            input_file = str(file_path)
            output_file = str(output_path / (file_path.name + '.enc'))
            
            total_input += file_path.stat().st_size
            total_output += encrypt_file(input_file, output_file, password)
            count += 1
            print()
    
    print(f"Batch complete:")
    print(f"  Files encrypted: {count}")
    print(f"  Total input: {total_input / 1024 / 1024:.2f} MB")
    print(f"  Total output: {total_output / 1024 / 1024:.2f} MB")


def generate_password(length: int = 32) -> str:
    """Generate a random password."""
    chars = string.ascii_letters + string.digits
    return ''.join(secrets.choice(chars) for _ in range(length))


def verify_file(encrypted_path: str, password: str) -> bool:
    """Verify an encrypted file can be decrypted."""
    # Create temp file for decryption test
    with tempfile.NamedTemporaryFile(delete=True) as tmp:
        try:
            decrypt_file(encrypted_path, tmp.name, password)
            print("\n✓ Verification successful - file can be decrypted")
            return True
        except Exception as e:
            print(f"\n✗ Verification failed: {e}")
            return False


def print_usage():
    """Print usage information."""
    usage = """
VM Launcher Asset Encryption Tool (Python)

Usage:
  python encrypt_assets.py <command> [options]

Commands:
  encrypt <input> <output> <password>
    Encrypt a single file

  decrypt <input> <output> <password>
    Decrypt a single file

  batch <input-dir> <output-dir> <password>
    Encrypt all files in a directory

  genkey [length]
    Generate a random password (default: 32 chars)

  verify <encrypted-file> <password>
    Verify an encrypted file can be decrypted

Examples:
  # Encrypt an ISO file
  python encrypt_assets.py encrypt exercise.iso exercise.iso.enc mySecretPassword

  # Decrypt it back
  python encrypt_assets.py decrypt exercise.iso.enc exercise.iso mySecretPassword

  # Encrypt entire assets folder
  python encrypt_assets.py batch ./assets ./encrypted-assets mySecretPassword

  # Generate a strong random password
  python encrypt_assets.py genkey

  # Generate a 64-character password
  python encrypt_assets.py genkey 64

  # Verify encryption
  python encrypt_assets.py verify exercise.iso.enc mySecretPassword

Requirements:
  pip install cryptography

Security Notes:
  - The password/key will be exposed in your JavaScript code on the client.
  - This encryption is meant to add friction, not provide true security.
  - For sensitive data, consider server-side authentication instead.
  - The same password must be used to encrypt and decrypt.
  - Use the same password in your VM Launcher config:
    {
      "encryption": {
        "enabled": true,
        "key": "mySecretPassword"
      }
    }
"""
    print(usage)


def main():
    if len(sys.argv) < 2:
        print_usage()
        sys.exit(0)
    
    command = sys.argv[1]
    
    try:
        if command == 'encrypt':
            if len(sys.argv) != 5:
                print("Usage: encrypt <input> <output> <password>")
                sys.exit(1)
            encrypt_file(sys.argv[2], sys.argv[3], sys.argv[4])
        
        elif command == 'decrypt':
            if len(sys.argv) != 5:
                print("Usage: decrypt <input> <output> <password>")
                sys.exit(1)
            decrypt_file(sys.argv[2], sys.argv[3], sys.argv[4])
        
        elif command == 'batch':
            if len(sys.argv) != 5:
                print("Usage: batch <input-dir> <output-dir> <password>")
                sys.exit(1)
            batch_encrypt(sys.argv[2], sys.argv[3], sys.argv[4])
        
        elif command == 'genkey':
            length = int(sys.argv[2]) if len(sys.argv) > 2 else 32
            password = generate_password(length)
            print(f"Generated password ({length} chars):")
            print(password)
        
        elif command == 'verify':
            if len(sys.argv) != 4:
                print("Usage: verify <encrypted-file> <password>")
                sys.exit(1)
            if not verify_file(sys.argv[2], sys.argv[3]):
                sys.exit(1)
        
        elif command in ('help', '--help', '-h'):
            print_usage()
        
        else:
            print(f"Unknown command: {command}")
            print_usage()
            sys.exit(1)
    
    except FileNotFoundError as e:
        print(f"Error: File not found - {e}")
        sys.exit(1)
    except PermissionError as e:
        print(f"Error: Permission denied - {e}")
        sys.exit(1)
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()
