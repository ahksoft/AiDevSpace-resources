curl -fsSL https://code-server.dev/install.sh | sh
cat > /bin/vsc << EOF 
code-server --bind-addr 0.0.0.0:6862 --auth none 
EOF
