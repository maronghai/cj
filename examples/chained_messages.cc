# chained_messages — 4-turn conversation with all roles
model gpt-4o-mini
messages+
    role system
    content "You are a helpful assistant."
    ,
    role user
    content "What's the weather in Paris?"
    ,
    role assistant
    content "I'll check that for you."
    ,
    role user
    content "Thanks!"
