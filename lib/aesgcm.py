#!/usr/bin/env python3
"""纯标准库 AES-256-GCM（cryptography 库不可用时的回退实现）。

供 crypto.sh 的 V3 加密包使用：
    ct, tag = gcm_encrypt(key32, nonce12, plaintext, aad)
    pt = gcm_decrypt(key32, nonce12, ct, tag, aad)  # 验签失败返回 None

正确性：tests/run.sh 用 cryptography 库做 20 轮随机交叉验证
（加密输出逐字节一致、互解密成功、篡改必被检出）。
"""


# ---------------- GF(2^8) 与 S 盒 ----------------

def _gf_mul(a, b):
    p = 0
    for _ in range(8):
        if b & 1:
            p ^= a
        hi = a & 0x80
        a = ((a << 1) & 0xFF) ^ (0x1B if hi else 0)
        b >>= 1
    return p


def _gf_pow(a, n):
    r = 1
    while n:
        if n & 1:
            r = _gf_mul(r, a)
        a = _gf_mul(a, a)
        n >>= 1
    return r


def _rotl8(x, n):
    n %= 8
    return ((x << n) | (x >> (8 - n))) & 0xFF if n else x & 0xFF


def _affine(x):
    return (x ^ _rotl8(x, 1) ^ _rotl8(x, 2)
            ^ _rotl8(x, 3) ^ _rotl8(x, 4) ^ 0x63) & 0xFF


_SBOX = tuple(_affine(_gf_pow(x, 254) if x else 0) for x in range(256))


# ---------------- AES-256 分组加密 ----------------

def _shift_rows(s):
    t = [0] * 16
    for r in range(4):
        for c in range(4):
            t[r + 4 * c] = s[r + 4 * ((c + r) % 4)]
    return t


def _mix_columns(s):
    t = [0] * 16
    for c in range(4):
        a0, a1, a2, a3 = s[4 * c], s[4 * c + 1], s[4 * c + 2], s[4 * c + 3]
        t[4 * c] = _gf_mul(a0, 2) ^ _gf_mul(a1, 3) ^ a2 ^ a3
        t[4 * c + 1] = a0 ^ _gf_mul(a1, 2) ^ _gf_mul(a2, 3) ^ a3
        t[4 * c + 2] = a0 ^ a1 ^ _gf_mul(a2, 2) ^ _gf_mul(a3, 3)
        t[4 * c + 3] = _gf_mul(a0, 3) ^ a1 ^ a2 ^ _gf_mul(a3, 2)
    return t


def _expand_key(key):
    """32 字节密钥 -> 15 个轮密钥（各 16 字节 list）。"""
    assert len(key) == 32
    w = [int.from_bytes(key[i:i + 4], "big") for i in range(0, 32, 4)]
    rcon = 1
    for i in range(8, 60):
        t = w[i - 1]
        if i % 8 == 0:
            t = ((_SBOX[(t >> 16) & 0xFF] << 24)
                 | (_SBOX[(t >> 8) & 0xFF] << 16)
                 | (_SBOX[t & 0xFF] << 8)
                 | _SBOX[(t >> 24) & 0xFF]) ^ (rcon << 24)
            rcon = _gf_mul(rcon, 2)
        elif i % 8 == 4:
            t = ((_SBOX[(t >> 24) & 0xFF] << 24)
                 | (_SBOX[(t >> 16) & 0xFF] << 16)
                 | (_SBOX[(t >> 8) & 0xFF] << 8)
                 | _SBOX[t & 0xFF])
        w.append(w[i - 8] ^ t)
    rks = []
    for r in range(15):
        rk = []
        for word in w[4 * r:4 * r + 4]:
            rk += [(word >> s) & 0xFF for s in (24, 16, 8, 0)]
        rks.append(rk)
    return rks


def _aes256_block(rks, block):
    s = [x ^ y for x, y in zip(block, rks[0])]
    for r in range(1, 14):
        s = [_SBOX[b] for b in s]
        s = _shift_rows(s)
        s = _mix_columns(s)
        s = [x ^ y for x, y in zip(s, rks[r])]
    s = [_SBOX[b] for b in s]
    s = _shift_rows(s)
    return bytes(x ^ y for x, y in zip(s, rks[14]))


# ---------------- GCM ----------------

_GHASH_R = 0xE1000000000000000000000000000000
_MASK128 = (1 << 128) - 1


def _gf128_mul(x, y):
    """GF(2^128) 乘法（NIST SP 800-38D 算法 1，R=0xe1||0^120）。"""
    z = 0
    for _ in range(128):
        if (y >> 127) & 1:
            z ^= x
        lsb = x & 1
        x >>= 1
        if lsb:
            x ^= _GHASH_R
        y = ((y << 1) & _MASK128)
    return z


def _ghash(h_int, aad, ct):
    data = (aad + b"\x00" * (-len(aad) % 16)
            + ct + b"\x00" * (-len(ct) % 16)
            + (len(aad) * 8).to_bytes(8, "big")
            + (len(ct) * 8).to_bytes(8, "big"))
    y = 0
    for i in range(0, len(data), 16):
        y ^= int.from_bytes(data[i:i + 16], "big")
        y = _gf128_mul(y, h_int)
    return y.to_bytes(16, "big")


def _xor(a, b):
    return bytes(x ^ y for x, y in zip(a, b))


class AESGCM256:
    def __init__(self, key):
        if len(key) != 32:
            raise ValueError("AES-256 需要 32 字节密钥")
        self._rks = _expand_key(bytes(key))
        self._h = int.from_bytes(
            _aes256_block(self._rks, bytes(16)), "big")

    def _block(self, b):
        return _aes256_block(self._rks, b)

    def encrypt(self, nonce, plaintext, aad=b""):
        if len(nonce) != 12:
            raise ValueError("GCM nonce 需 12 字节")
        plaintext = bytes(plaintext)
        aad = bytes(aad or b"")
        j0 = bytes(nonce) + b"\x00\x00\x00\x01"
        ctr = int.from_bytes(j0, "big")
        ct = bytearray()
        for i in range(0, len(plaintext), 16):
            ctr += 1
            ks = self._block(ctr.to_bytes(16, "big"))
            blk = plaintext[i:i + 16]
            ct += _xor(blk, ks[:len(blk)])
        ct = bytes(ct)
        tag = _xor(_ghash(self._h, aad, ct), self._block(j0))
        return ct, tag

    def decrypt(self, nonce, ciphertext, tag, aad=b""):
        if len(nonce) != 12 or len(tag) != 16:
            return None
        ciphertext = bytes(ciphertext)
        aad = bytes(aad or b"")
        j0 = bytes(nonce) + b"\x00\x00\x00\x01"
        expect = _xor(_ghash(self._h, aad, ciphertext), self._block(j0))
        # 常量时间比较
        diff = 0
        for x, y in zip(expect, tag):
            diff |= x ^ y
        if diff:
            return None
        ctr = int.from_bytes(j0, "big")
        pt = bytearray()
        for i in range(0, len(ciphertext), 16):
            ctr += 1
            ks = self._block(ctr.to_bytes(16, "big"))
            blk = ciphertext[i:i + 16]
            pt += _xor(blk, ks[:len(blk)])
        return bytes(pt)


def gcm_encrypt(key, nonce, plaintext, aad=b""):
    """-> (ciphertext, tag16)。"""
    return AESGCM256(key).encrypt(nonce, plaintext, aad)


def gcm_decrypt(key, nonce, ciphertext, tag, aad=b""):
    """验签失败返回 None，否则返回明文。"""
    return AESGCM256(key).decrypt(nonce, ciphertext, tag, aad)


if __name__ == "__main__":
    # 自检：空输入下 tag 应为 E(K, J0)；与全零向量的结构一致性
    ct, tag = gcm_encrypt(bytes(32), bytes(12), b"", b"")
    assert ct == b"" and len(tag) == 16
    assert gcm_decrypt(bytes(32), bytes(12), b"", tag, b"") == b""
    assert gcm_decrypt(bytes(32), bytes(12), b"", b"\x00" * 16, b"") is None
    print("aesgcm 自检通过")
