# long_prompt — uses """...""" for a multi-line system prompt
model gpt-4o-mini
messages+
    role system
    content """
        You are a helpful coding assistant.

        Rules:
        1. Always use TypeScript.
        2. Never use `any`.
        3. Write tests for everything.

        Be concise.
        """
    ,
    role user
    content Write a function that adds two numbers.
