from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8045/v1",
    api_key="sk-113ca1600de14eee8e49735121ce0be5"
)

response = client.chat.completions.create(
    model="claude-opus-4-6",
    messages=[{"role": "user", "content": "你是什么模型"}],
    max_tokens=1024  # Claude 系列模型必须显式指定此参数
)

print(response.choices[0].message.content)