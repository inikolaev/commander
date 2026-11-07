#!/usr/bin/env python3
"""Convert macOS sample call trees to folded stacks, SVG and an interactive HTML flame graph."""
import argparse
import collections
import hashlib
import html
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument("sample", type=Path)
parser.add_argument("output", type=Path, help="Output prefix")
parser.add_argument("--root", default="benchmarkLoad(_:)", help="Sampled function at the root of the flame graph")
parser.add_argument("--title", default="Commander · 100 MiB editor load")
args = parser.parse_args()
text = args.sample.read_text()
graph = text.split("Call graph:\n", 1)[1].split("\nTotal number", 1)[0]
roots, parents = [], []
for line in graph.splitlines():
    match = re.match(r"^([ +!:|]*)(\d+) (.+)$", line)
    if not match:
        continue
    column = len(match[1])
    raw = match[3]
    name = raw.split("  (in ", 1)[0]
    node = dict(name=name, count=int(match[2]), children=[])
    while parents and parents[-1][0] >= column:
        parents.pop()
    (parents[-1][1]["children"] if parents else roots).append(node)
    parents.append((column, node))

folded = collections.Counter()
def visit(node, path):
    path = path + [node["name"]]
    children = sum(child["count"] for child in node["children"])
    assert children <= node["count"], (node["name"], children, node["count"])
    own = node["count"] - children
    if own and args.root in path:
        path = path[path.index(args.root):]
        folded[tuple(path)] += own
    for child in node["children"]:
        visit(child, path)
for node in roots:
    visit(node, [])

assert folded, f"No {args.root} samples found"
tree = dict(name=args.root, count=0, children={})
for stack, count in folded.items():
    node = tree
    node["count"] += count
    for frame in stack[1:]:
        node = node["children"].setdefault(frame, dict(name=frame, count=0, children={}))
        node["count"] += count
def pack(node):
    return dict(name=node["name"], count=node["count"],
                children=[pack(c) for c in sorted(node["children"].values(), key=lambda x: (-x["count"], x["name"]))])
tree = pack(tree)
prefix = args.output
prefix.parent.mkdir(parents=True, exist_ok=True)
prefix.with_suffix(".folded").write_text("".join(";".join(stack).replace("\n", " ") + f" {count}\n" for stack, count in sorted(folded.items())))
prefix.with_suffix(".json").write_text(json.dumps(tree, indent=2))

inclusive, own = collections.Counter(), collections.Counter()
for stack, count in folded.items():
    for name in set(stack):
        inclusive[name] += count
    own[stack[-1]] += count
summary = "\n".join(f"{count:6d} {count/tree['count']*100:6.2f}% self={own[name]:5d} {name}"
                    for name, count in inclusive.most_common(25))
prefix.with_suffix(".summary.txt").write_text(summary + "\n")
print("Samples:", tree["count"])
print(summary)

def depth(node):
    return 1 + max((depth(c) for c in node["children"]), default=0)
width, row = 1600, 20
height = 105 + row * depth(tree)
parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
         '<rect width="100%" height="100%" fill="#faf8f3"/>',
         '<style>text{font:12px monospace;pointer-events:none}rect.frame{stroke:white;stroke-width:.4}</style>',
         f'<text x="16" y="25" style="font:bold 19px sans-serif">{html.escape(args.title)} · sampled flame graph</text>',
         f'<text x="16" y="49">{tree["count"]} samples · 1 ms interval · release · width = inclusive samples</text>',
         '<text x="16" y="70">This is not a timeline or an allocation graph.</text>']
def draw(node, x, level):
    w = (width - 32) * node["count"] / tree["count"]
    y = height - 10 - (level + 1) * row
    hue = int(hashlib.sha256(node["name"].encode()).hexdigest()[:4], 16) % 55
    label = html.escape(node["name"])
    parts.append(f'<g><title>{label}: {node["count"]} samples ({node["count"]/tree["count"]:.2%})</title><rect class="frame" x="{x:.2f}" y="{y}" width="{w:.2f}" height="19" fill="hsl({hue},85%,70%)"/>')
    if w > 28:
        short = node["name"][:max(1, int((w-8)/7))]
        parts.append(f'<text x="{x+3:.2f}" y="{y+14}">{html.escape(short)}</text>')
    parts.append('</g>')
    childx = x
    for child in node["children"]:
        draw(child, childx, level+1)
        childx += (width-32)*child["count"]/tree["count"]
draw(tree, 16, 0)
parts.append('</svg>')
prefix.with_suffix(".svg").write_text("\n".join(parts))

page = """<!doctype html><meta charset="utf-8"><title>Commander editor flame graph</title>
<style>body{margin:24px;background:#faf8f3;color:#252525;font:15px system-ui}h1{font-size:24px}
button,input{font:inherit;padding:6px;margin-right:10px}#detail{min-height:44px;font-family:monospace}
svg{width:100%;min-width:900px}svg text{font:12px monospace;pointer-events:none}
.frame{stroke:#fff;stroke-width:.5;cursor:pointer}.frame:hover{stroke:#222;stroke-width:2}</style>
<h1>TITLE</h1>
<p>Release build, 1 ms stack sampling. Width = inclusive sample count.
This is not a timeline. Click a frame to zoom.</p>
<button id="reset">Reset</button><button id="back">Back</button><input id="search" placeholder="Highlight function…">
<p id="detail"></p><div id="graph"></div>
<script>
const root=DATA;
const total=root.count, history=[];
let current=root;
const ns='http://www.w3.org/2000/svg';
function el(tag,attrs,parent){const n=document.createElementNS(ns,tag);for(const [k,v] of Object.entries(attrs))n.setAttribute(k,v);parent.append(n);return n;}
function dep(n){return 1+Math.max(0,...n.children.map(dep));}
function render(){
 const host=document.getElementById('graph');host.replaceChildren();
 const width=1600,height=30+20*dep(current);
 const svg=el('svg',{viewBox:'0 0 '+width+' '+height},host);
 const query=document.getElementById('search').value.toLowerCase();
 document.getElementById('detail').textContent=current.name+' — '+current.count+' samples; '+(100*current.count/total).toFixed(2)+'% of selected profile';
 function draw(n,x,level){
  const w=width*n.count/current.count,y=height-25-level*20;
  let hash=0;for(const c of n.name)hash=(hash*31+c.charCodeAt(0))>>>0;
  const match=query&&n.name.toLowerCase().includes(query);
  const r=el('rect',{x,y,width:w,height:19,class:'frame',fill:match?'#ec7dcb':'hsl('+(hash%55)+',85%,70%)'},svg);
  el('title',{},r).textContent=n.name+' — '+n.count+' samples ('+(100*n.count/total).toFixed(2)+'% of selected profile)';
  r.onclick=()=>{history.push(current);current=n;render();};
  if(w>28)el('text',{x:x+3,y:y+14},svg).textContent=n.name.slice(0,Math.max(1,Math.floor((w-8)/7)));
  let next=x;for(const c of n.children){draw(c,next,level+1);next+=width*c.count/current.count;}
 }draw(current,0,0);
}
document.getElementById('reset').onclick=()=>{history.length=0;current=root;render();};
document.getElementById('back').onclick=()=>{if(history.length){current=history.pop();render();}};
document.getElementById('search').oninput=render;
render();
</script>"""
prefix.with_suffix(".html").write_text(
    page.replace("TITLE", html.escape(args.title)).replace("DATA", json.dumps(tree).replace("<", "\\u003c")))
