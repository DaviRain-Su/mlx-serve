cask "mlx-core" do
  version "26.5.2"
  sha256 "c587b142a45f71f126757e70f86d91e809e5b1b17695794557dc0a24c82820d4"

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
