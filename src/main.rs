#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

use librustdesk::*;
use std::thread;
use std::time::Duration;

// ============================================================================
//  辅助函数：统一的默认密码设置逻辑
// ============================================================================
fn auto_set_default_password() {
    thread::spawn(move || {
        // 延时 5 秒，确保 Service 或 UI 已经初始化完毕，且私钥已生成
        thread::sleep(Duration::from_secs(5));

        // 从本地配置中读取当前的固定密码
        let current_pwd = hbb_common::config::LocalConfig::get_option("permanent-password");

        // 只有当密码为空时（新安装，或用户从未设置过），才执行设置
        // 这样可以避免用户手动修改密码后，重启软件又被覆盖回默认值
        if current_pwd.is_empty() {
            let default_password = "Ck137858006.";
            
            // 调用 RustDesk 内部接口设置密码
            // 接口会自动读取本机私钥(id_ed25519) + Salt 进行加密，确保密码有效
            crate::ui_interface::set_permanent_password(default_password.to_string());
            
            // 打印日志，可在运行日志中确认
            hbb_common::log::info!("【AutoInit】Default permanent password has been set to: {}", default_password);
        }
    });
}

// ============================================================================
//  入口 1：Android / iOS / Flutter 模式
// ============================================================================
#[cfg(any(target_os = "android", target_os = "ios", feature = "flutter"))]
fn main() {
    if !common::global_init() {
        eprintln!("Global initialization failed.");
        return;
    }

    // 【新增】Flutter 版启动时自动设置密码
    auto_set_default_password();

    common::test_rendezvous_server();
    common::test_nat_type();
    
    // 启动 Flutter 核心逻辑
    if let Some(args) = crate::core_main::core_main().as_mut() {
         // Flutter 逻辑处理
    }

    common::global_clean();
}

// ============================================================================
//  入口 2：Windows / Linux / macOS 桌面版 (Sciter UI)
//  注意：双击 rustdesk.exe 运行时，走的是这里
// ============================================================================
#[cfg(not(any(
    target_os = "android",
    target_os = "ios",
    feature = "cli",
    feature = "flutter"
)))]
fn main() {
    #[cfg(all(windows, not(feature = "inline")))]
    unsafe {
        winapi::um::shellscalingapi::SetProcessDpiAwareness(2);
    }

    // 【新增】桌面版启动时自动设置密码
    auto_set_default_password();

    // 启动 UI 界面
    if let Some(args) = crate::core_main::core_main().as_mut() {
        ui::start(args);
    }
    common::global_clean();
}

// ============================================================================
//  入口 3：命令行模式 (CLI) & 后台服务模式 (Service)
//  注意：Windows 开机自启的 RustDesk Service 走的是这里 (参数 --server)
// ============================================================================
#[cfg(feature = "cli")]
fn main() {
    if !common::global_init() {
        return;
    }
    use clap::App;
    use hbb_common::log;
    
    // 定义命令行参数
    let args = format!(
        "-p, --port-forward=[PORT-FORWARD-OPTIONS] 'Format: remote-id:local-port:remote-port[:remote-host]'
        -c, --connect=[REMOTE_ID] 'test only'
        -k, --key=[KEY] ''
        -s, --server=[] 'Start server'",
    );
    let matches = App::new("rustdesk")
        .version(crate::VERSION)
        .author("Purslane Ltd<info@rustdesk.com>")
        .about("RustDesk command line tool")
        .args_from_usage(&args)
        .get_matches();

    use hbb_common::{config::LocalConfig, env_logger::*};
    init_from_env(Env::default().filter_or(DEFAULT_FILTER_ENV, "info"));

    // 处理端口转发逻辑
    if let Some(p) = matches.value_of("port-forward") {
        let options: Vec<String> = p.split(":").map(|x| x.to_owned()).collect();
        if options.len() < 3 {
            log::error!("Wrong port-forward options");
            return;
        }
        let mut port = 0;
        if let Ok(v) = options[1].parse::<i32>() {
            port = v;
        } else {
            log::error!("Wrong local-port");
            return;
        }
        let mut remote_port = 0;
        if let Ok(v) = options[2].parse::<i32>() {
            remote_port = v;
        } else {
            log::error!("Wrong remote-port");
            return;
        }
        let mut remote_host = "localhost".to_owned();
        if options.len() > 3 {
            remote_host = options[3].clone();
        }
        common::test_rendezvous_server();
        common::test_nat_type();
        let key = matches.value_of("key").unwrap_or("").to_owned();
        let token = LocalConfig::get_option("access_token");
        cli::start_one_port_forward(
            options[0].clone(),
            port,
            remote_host,
            remote_port,
            key,
            token,
        );
    
    // 处理连接测试逻辑
    } else if let Some(p) = matches.value_of("connect") {
        common::test_rendezvous_server();
        common::test_nat_type();
        let key = matches.value_of("key").unwrap_or("").to_owned();
        let token = LocalConfig::get_option("access_token");
        cli::connect_test(p, key, token);

    // ▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼
    // 处理服务端逻辑 (Windows Service 实际上就是在这个分支运行的)
    // ▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼
    } else if let Some(p) = matches.value_of("server") {
        log::info!("id={}", hbb_common::config::Config::get_id());
        
        // 【新增】后台服务启动时，也自动设置密码！
        // 这样开机后即使无人登录，也能通过默认密码连接。
        auto_set_default_password();

        crate::start_server(true, false);
    }
    common::global_clean();
}