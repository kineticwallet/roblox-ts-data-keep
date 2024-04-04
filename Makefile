update:
	pnpm update

install:
	pnpm install --shamefully-hoist
	aftman install

build:
	pnpm exec rbxtsc build --verbose --logTruthyChanges

format:
	pnpm exec biome format . --write --verbose
	stylua src -g "**/*.lua" --verify
	stylua dist -g "**/*.lua" --verify
