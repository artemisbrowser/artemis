// The canvas a tracker would read, hashed here and sent nowhere. Each site's number stands in for
// Artemis's per-site noise: this page's hash mixed with the site's name.
const fp = document.querySelector(".prv-fp");
const fnv = (s) => {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return h;
};
const hex = (n) => (n >>> 0).toString(16).padStart(8, "0").replace(/^.{4}/, "$& ");
const c = document.createElement("canvas");
c.width = 200;
c.height = 40;
const x = c.getContext("2d");
const g = x.createLinearGradient(0, 0, 200, 40);
g.addColorStop(0, "#4a8fd8");
g.addColorStop(1, "#e0845a");
x.fillStyle = g;
x.fillRect(0, 0, 200, 40);
x.fillStyle = "#fff";
x.font = "600 22px system-ui";
x.fillText("Artemis ✦ 26", 10, 28);
const h = fnv(c.toDataURL());
fp.querySelector("b").textContent = hex(h);
for (const d of fp.querySelectorAll("dd"))
  d.textContent = hex(h ^ fnv(d.previousElementSibling.textContent));
