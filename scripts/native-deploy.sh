#!/bin/bash

# 构建与部署

if [ ! -x "/usr/bin/expect" ]; then
  echo "The executable command expect is required."
  exit 1
fi

basedir=$(cd "$(dirname "$0")" && pwd)

is_exit=0

. $basedir/common.sh

options="{full|go_and_vue|go|vue|supervisor|views|config|restart_supervisor|restart_nginx|build_darwin|build_windows
full: supervisor、go、vue的编译、安装与部署
go_and_vue: go、vue构建与部署
go: go的构建
vue: vue的构建
supervisor: supervisor的安装检测与配置更新
build_darwin: 构建基于mac os的可运行go程序
build_windows: 构建基于windows的可运行go程序
"
if [ $is_exit -eq 1 ]; then
  echo "Usage: $0 $options"
  exit 1
fi

# supervisord.conf 配置
update_supervisor_config() {
  tee $config/supervisord.conf <<EOF
[program:$PROJECT_NAME]
command=$GO_PROJ_DIST/bin/$PROJECT_NAME -w $GO_PROJ_DIST
user=$USER
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=$GO_PROJ_DIST/logs/$PROJECT_NAME.log
stopsignal=15
stopasgroup=true
killasgroup=true
EOF
}

# shellcheck disable=SC1073
AskPassword=$(cat <<-EOF
expect {
  "*请输入密码*" { send "$PASSWORD\r" }
  "*password*" { send "$PASSWORD\r" }
  "*yes/no*" { send "yes\r" }
  "*#|*$" { send "\r" }
  "sftp>" { send "\r" }
  eof { send_tty "eof, will exit.\n"; exit }
}
EOF
)

# 执行远程命令
remoteShell() {
  /usr/bin/expect <<-EOF
set timeout -1
if { "$JUMP_HOST_NAME" == "" } {
  spawn ssh $2 -p$PORT $USER@$HOST "$1"
} else {
  spawn ssh $2 $JUMP_HOST_NAME "$1"
}

$AskPassword
$AskPassword

expect eof
EOF
}

# 上传文件
remoteSftp() {
  /usr/bin/expect <<-EOF
set timeout -1
if { "$JUMP_HOST_NAME" == "" } {
  spawn sftp -p$PORT $USER@$HOST
} else {
  spawn sftp $JUMP_HOST_NAME
}

$AskPassword
$AskPassword

expect "sftp>"
send "put $1 $2\r"
expect "sftp>"
send "bye\r"
expect eof
EOF
}

# 验证预期关键字是否存在
checkExists() {
  echo $1|grep -ow "{succ}"|wc -l
}

run() {
  case $1 in
  "full")
    # 全量部署包含 supervisor / go / vue 服务与应用
    run supervisor
    run go_and_vue
  ;;
  "go_and_vue")
    # 部署 go / vue 资源，并重启相关服务
    run go
    run views
    run config
    run vue
  ;;
  "views")
    # 上送静态模板
    remoteShell "mkdir -p $GO_PROJ_DIST/web && rm -rf $GO_PROJ_DIST/web/*"
    remoteSftp "-r $basedir/../src/backend/web/views" $GO_PROJ_DIST/web
  ;;
  "supervisor")
    echo "deploy supervisor start"
    # 检查 supervisor 是否安装
    ok=$(remoteShell "which supervisorctl && echo {succ}")
    ok=$(echo $ok|grep -ow "{succ}"|wc -l)
    if [ "$ok" -lt "2" ]; then
      echo "Not found supervisorctl. Please apt-get install supervisor."
      exit 1
    fi
    # 生成配置文件
    update_supervisor_config
    # 上送配置
    remoteSftp $config/supervisord.conf /tmp/supervisord.conf
    # 配置文件归位
    remoteShell "sudo mv /tmp/supervisord.conf /etc/supervisor/conf.d/$PROJECT_NAME.conf" "-t"
    echo "deploy supervisor end"
  ;;
  "restart_supervisor")
    # 重启 supervisor
    remoteShell "sudo systemctl restart supervisor" "-t"
  ;;
  "restart_nginx")
    # 重启 nginx
    remoteShell "sudo systemctl restart nginx" "-t"
  ;;
  "config")
    # 上送配置文件
    remoteSftp $config/config.yaml /tmp/config.yaml
    # 转移至项目目录
    remoteShell "mkdir -p $GO_PROJ_DIST && mv /tmp/config.yaml $GO_PROJ_DIST/config.yaml"
    run restart_supervisor
  ;;
  "vue")
    # vue构建与上送
    cd $basedir/../src/frontend/ && npm run build && cd -
    remoteShell "mkdir -p $STATIC_PROJ_DIST && rm -rf $STATIC_PROJ_DIST/*"
    remoteSftp "-r $basedir/../src/frontend/dist/*" $STATIC_PROJ_DIST
    run restart_nginx
  ;;
  "go")
    # 构建 go
    build_sock linux
    # 不管目录是否存在仍创建
    remoteShell "mkdir -p $GO_PROJ_DIST/{bin,logs}"
    # 上送到指定目录
    PROJ_NAME=$PROJECT_NAME.`date +%s`
    remoteSftp $PROJECT $GO_PROJ_DIST/bin/$PROJ_NAME
    # 创建执行程序软连接
    remoteShell "ln -sf $GO_PROJ_DIST/bin/$PROJ_NAME $GO_PROJ_DIST/bin/$PROJECT_NAME"
    run restart_supervisor
  ;;
  "build_windows")
    build_sock windows
  ;;
  "build_darwin")
    build_sock darwin
  ;;
  *)
    echo "Usage: $0 $options"
  ;;
  esac
}

run $1
