# 品牌素材

两组文件并存，**不要删掉任一组**：

| 目录 | 内容 | 规格 | 用途 |
|---|---|---|---|
| `./` | `logo1-4.png`、`user1-6.png` | 2048×2048 PNG，共 27MB | 母版源图，供后续改尺寸/改造 |
| `compressed/` | 同名 `.webp` | logo 512×512、头像 200×200，共 88KB | 实际接入 Casdoor 时使用 |

源图体积大且当前未被任何配置引用，线上/配置里只引用 `compressed/`，避免把 27MB 拖进镜像。

## 重新生成

需要 `cwebp`（`brew install webp`）：

```bash
# 品牌标识：512×512，q=88，剔除元数据
for i in 1 2 3 4; do
  cwebp -q 88 -m 6 -resize 512 512 -metadata none "logo$i.png" -o "compressed/logo$i.webp"
done

# 用户头像：200×200，q=82
for i in 1 2 3 4 5 6; do
  cwebp -q 82 -m 6 -resize 200 200 -metadata none "user$i.png" -o "compressed/user$i.webp"
done
```

## 已知问题

- `logo1-4.png` 右下角带「即梦AI」水印。作为对外品牌标识前需换用无水印版本；替换时新增文件即可，历史里的旧图无法原地改写。
