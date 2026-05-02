@Entry
@Component
struct NoteProbePage {
  build() {
    Column() {
      Text('Note probe page loaded')
        .fontSize(20)
        .fontColor('#1A1A1A')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
