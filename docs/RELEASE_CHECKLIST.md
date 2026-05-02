# HarmonyOS 应用发布检查清单

## 应用信息
- **应用名称**: xiaozhou
- **包名**: io.github.hope02.xiaozhou
- **版本号**: 1.0.2
- **版本代码**: 1000000
- **设备类型**: phone

## 构建输出文件
构建已成功完成，生成的文件位于 `build/outputs/default/` 目录：

### 已签名的应用包
- **文件**: `xiaozhou-default-signed.app`
- **大小**: 872,095 字节
- **签名状态**: 已使用release证书签名
- **最后修改时间**: 2026-04-25 11:15:39

### 未签名的应用包
- **文件**: `xiaozhou-default-unsigned.app`
- **大小**: 857,312 字节
- **最后修改时间**: 2026-04-25 11:15:39

## 签名配置
应用已配置release签名，使用以下证书：
- **证书类型**: HarmonyOS
- **证书路径**: `C:\Users\hope\.ohos\config\release_xiaozhou_pfOWex1A6AOVBMdBnQMXW5wjiuRhpyxrYOz6x9OG748=.cer`
- **密钥别名**: debugKey
- **签名算法**: SHA256withECDSA

## 应用商店发布准备

### 1. 验证应用包
在发布前，请验证：
- [ ] 应用包已正确签名
- [ ] 应用图标和名称符合规范
- [ ] 权限配置正确（仅INTERNET权限）
- [ ] 应用功能测试通过

### 2. 应用商店要求
确保满足以下要求：
- [ ] 应用描述完整
- [ ] 截图准备就绪
- [ ] 隐私政策链接（如需要）
- [ ] 年龄分级设置
- [ ] 定价策略设置

### 3. 上传到应用商店
1. 登录华为开发者联盟
2. 进入"我的项目" -> "应用管理"
3. 创建新应用或选择现有应用
4. 上传 `xiaozhou-default-signed.app` 文件
5. 填写应用详情信息
6. 提交审核

## 构建命令参考
```bash
# 构建release包
hvigorw PackageApp -Pproduct=release

# 签名release包
hvigorw SignApp -Pproduct=release

# 查看构建任务
hvigorw tasks
```

## 注意事项
1. 确保release证书有效且未过期
2. 上传前建议在真机上测试应用
3. 检查所有功能在release模式下正常工作
4. 确保应用符合华为应用商店审核规范

## 技术支持
- 华为开发者联盟: https://developer.huawei.com/consumer/cn/
- HarmonyOS开发文档: https://developer.harmonyos.com/cn/docs/documentation/doc-guides-V3/