import os, re, zipfile, sys
import xml.etree.ElementTree as ET

SRC = r'D:\fpga\赛题目标'
OUT = r'D:\fpga\project\tmp_competition'
os.makedirs(OUT, exist_ok=True)

pdf_path = os.path.join(SRC, "全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-安路科技 (1).pdf")
pptx_path = os.path.join(SRC, '赛题解析一 (1).pptx')

# ---------------- PDF ----------------
try:
    import fitz
    doc = fitz.open(pdf_path)
    parts = []
    for i, page in enumerate(doc):
        parts.append(f"\n{'='*70}\n[PDF 第 {i+1} 页 / 共 {len(doc)} 页]\n{'='*70}")
        parts.append(page.get_text("text"))
    txt = "\n".join(parts)
    with open(os.path.join(OUT, 'pdf_text.txt'), 'w', encoding='utf-8') as f:
        f.write(txt)
    print(f"PDF: {len(doc)} pages, {len(txt)} chars -> pdf_text.txt")
except Exception as e:
    print("PDF FAILED:", e)

# ---------------- PPTX ----------------
A = '{http://schemas.openxmlformats.org/drawingml/2006/main}'
def slide_key(name):
    m = re.search(r'(\d+)\.xml$', name)
    return int(m.group(1)) if m else 0

def extract(xml_bytes):
    root = ET.fromstring(xml_bytes)
    out = []
    for p in root.iter(A + 'p'):
        line = ''.join(t.text or '' for t in p.iter(A + 't'))
        if line.strip():
            out.append(line)
    return out

try:
    z = zipfile.ZipFile(pptx_path)
    names = z.namelist()
    slides = sorted([n for n in names if re.match(r'ppt/slides/slide\d+\.xml$', n)], key=slide_key)
    notes  = sorted([n for n in names if re.match(r'ppt/notesSlides/notesSlide\d+\.xml$', n)], key=slide_key)
    parts = []
    for n in slides:
        idx = slide_key(n)
        parts.append(f"\n{'='*70}\n[PPT 第 {idx} 页]\n{'='*70}")
        parts.extend(extract(z.read(n)))
    if notes:
        parts.append(f"\n\n{'#'*70}\n# 备注页\n{'#'*70}")
        for n in notes:
            idx = slide_key(n)
            body = extract(z.read(n))
            if body:
                parts.append(f"\n--- 备注 {idx} ---")
                parts.extend(body)
    txt = "\n".join(parts)
    with open(os.path.join(OUT, 'pptx_text.txt'), 'w', encoding='utf-8') as f:
        f.write(txt)
    print(f"PPTX: {len(slides)} slides, {len(notes)} notes, {len(txt)} chars -> pptx_text.txt")
except Exception as e:
    print("PPTX FAILED:", e)
