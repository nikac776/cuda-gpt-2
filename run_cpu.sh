#!/bin/bash

# Compile C code
gcc -O3 cpu/c_chat_gpt_2.c -lm -o cpu/c_chat_gpt_2

# Run the program
./cpu/c_chat_gpt_2 gpt2-124M.ckpt vocab.bpe "$(echo -e "\nAlice: Hello, how are you doing today?\nBob: I am doing well. I am a language model trained by OpenAI. How can I assist you?\nAlice: Can you answer my questions?\nBob: Yes I will answer your questions. What do you want to know?\nAlice: What is your name?\nBob: My name is Bob.\nAlice: Nice to meet you Bob. I'm alice.\nBob: How can I help you?")" 512