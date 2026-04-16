cask "mlx-core" do
  version "26.4.25"
  sha256 "c7ceb7c66fd5ac44b2840cb79ab28a4cc20b213f37e5ea22e1718d892a9f0753"

  url "https://github.com/ddalcu/mlx-serve/releases/download/v#{version}/MLXCore.dmg"
  name "MLX Core"
  desc "Native LLM server for Apple Silicon with OpenAI & Anthropic compatible APIs"
  homepage "https://github.com/ddalcu/mlx-serve"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "MLX Core.app"

  zap trash: [
    "~/.mlx-serve",
  ]
end
