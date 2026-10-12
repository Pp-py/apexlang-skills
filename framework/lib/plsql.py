"""plsql — the PL/SQL lexer the package scans share (apex-security's plsql-scan.py,
apexlang-architecture's arch-scan.py).

  mask(text)    the text with comments and literal contents blanked, same length and lines,
                so a regex over it never matches inside a comment or a string
  LexError      an unclosed literal or comment: the scan reports the file as unparsed
"""


class LexError(Exception):
    pass


def mask(text):
    """The text with comments blanked and literal contents blanked (quotes kept, a q'[…]'
    becomes '   '); same length, newlines kept, so offsets map to the original lines."""
    out, i, n = list(text), 0, len(text)

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "
    while i < n:
        c, two = text[i], text[i:i + 2]
        if two == "--":
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif two == "/*":
            j = text.find("*/", i + 2)
            if j < 0:
                raise LexError(f"line {text.count(chr(10), 0, i) + 1}: unclosed comment")
            blank(i, j + 2)
            i = j + 2
        elif c in "qQ" and text[i + 1:i + 2] == "'" and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            close = {"[": "]", "(": ")", "{": "}", "<": ">"}.get(text[i + 2:i + 3], text[i + 2:i + 3])
            j = text.find(close + "'", i + 3)
            if j < 0:
                raise LexError(f"line {text.count(chr(10), 0, i) + 1}: unclosed q-quoted literal")
            blank(i, j + 2)
            out[i + 1], out[j + 1] = "'", "'"
            i = j + 2
        elif c == "'":
            j = i + 1
            while True:
                j = text.find("'", j)
                if j < 0:
                    raise LexError(f"line {text.count(chr(10), 0, i) + 1}: unclosed literal")
                if text[j + 1:j + 2] == "'":
                    j += 2
                    continue
                break
            blank(i + 1, j)
            i = j + 1
        else:
            i += 1
    return "".join(out)
