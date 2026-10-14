#!/usr/bin/env python3
"""把 data.json 内联进 template.html，产出单文件、离线可用的 index.html。

不内联而用 fetch 的话，file:// 打开会被 CORS 挡住 —— 这个页面必须能直接双击打开。
"""
import json
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
TPL = os.path.join(ROOT, "template.html")
DAT = os.path.join(ROOT, "data.json")
OUT = os.path.join(ROOT, "index.html")


def main():
    with open(DAT, encoding="utf-8") as f:
        data = json.load(f)
    with open(TPL, encoding="utf-8") as f:
        tpl = f.read()

    assert "__DATA_JSON__" in tpl, "模板里没有 __DATA_JSON__ 占位符"
    # ensure_ascii=False 保留中文；</script> 转义防提前闭合
    blob = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    blob = blob.replace("</", "<\\/")
    html = tpl.replace("__DATA_JSON__", blob)

    with open(OUT, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"OK  {OUT}  {len(html):,} bytes")


if __name__ == "__main__":
    main()
